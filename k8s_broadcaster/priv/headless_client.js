"use strict";

const puppeteer = require("puppeteer");

const url =
  process.env.URL === undefined ? "http://localhost:4000" : process.env.URL;
const token = process.env.TOKEN === undefined ? "example" : process.env.TOKEN;

async function stream(token) {
  console.log("Starting new stream...");
  let response;

  const localStream = await navigator.mediaDevices.getUserMedia({
    video: {
      width: { ideal: 1280 },
      height: { ideal: 720 },
      frameRate: { ideal: 24 },
    },
    audio: true,
  });

  response = await fetch("/api/pc-config", {
    method: "GET",
    cache: "no-cache",
  });
  const pcConfig = await response.json();
  console.log("Fetched PC config from server: ", pcConfig);

  const pc = new RTCPeerConnection(pcConfig);
  pc.onconnectionstatechange = async (_) => {
    console.log("Connection state changed:", pc.connectionState);
    if (pc.connectionState === "failed") {
      stream(token);
    }
  };

  pc.addTrack(localStream.getAudioTracks()[0], localStream);
  pc.addTransceiver(localStream.getVideoTracks()[0], {
    streams: [localStream],
    sendEncodings: [
      { rid: "h", maxBitrate: 1500 * 1024 },
      { rid: "m", scaleResolutionDownBy: 2, maxBitrate: 600 * 1024 },
      { rid: "l", scaleResolutionDownBy: 4, maxBitrate: 300 * 1024 },
    ],
  });

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);

  response = await fetch("/api/whip", {
    method: "POST",
    cache: "no-cache",
    headers: {
      Accept: "application/sdp",
      "Content-Type": "application/sdp",
      Authorization: `Bearer ${token}`,
    },
    body: offer.sdp,
  });

  if (response.status !== 201) {
    throw Error("Unable to connect to the server");
  }

  const sdp = await response.text();
  await pc.setRemoteDescription({ type: "answer", sdp: sdp });
}

async function start() {
  let browser;

  try {
    console.log("Initialising the browser...");
    browser = await puppeteer.launch({
      args: [
        "--no-sandbox",
        "--use-fake-ui-for-media-stream",
        "--use-fake-device-for-media-stream",
      ],
    });
    const page = await browser.newPage();
    page.on("console", (msg) => console.log("Page log:", msg.text()));

    // We need a page with secure context in order to access userMedia.
    // Note: this might cause a redirect. E.g. when we are behind proxy,
    // url passed by env var, will be http://example.com:80, but we will
    // be redirected to https://example.com:443.
    // Because of that, we implicitly rely on window.location.origin later on.
    await page.goto(`${url}/notfound`);

    await page.evaluate(stream, token);
  } catch (err) {
    console.error("Browser error occured:", err);
    if (browser) await browser.close();
  }
}

start();
