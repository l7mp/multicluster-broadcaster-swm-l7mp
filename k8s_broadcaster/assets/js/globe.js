// This code is taken from https://github.com/janarosmonaliev/github-globe
// and slightly adjusted to our needs

import ThreeGlobe from "three-globe";
import * as THREE from "three";
import countries from "./files/globe-data-min.json";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";

function initRenderer(width, height) {
  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(window.devicePixelRatio);
  renderer.setSize(width, height);
  return renderer;
}

function initGlobe() {
  const globe = new ThreeGlobe({
    waitForGlobeReady: true,
    animateIn: true,
  })
    .hexPolygonsData(countries.features)
    .hexPolygonResolution(3)
    .hexPolygonMargin(0.7)
    .showAtmosphere(true)
    .atmosphereColor("#3a228a")
    .atmosphereAltitude(0.25)
    .hexPolygonColor((e) => {
      return "rgba(255,255,255, 0.7)";
    });

  globe.rotateY(-Math.PI * (5 / 9));
  globe.rotateZ(-Math.PI / 6);
  const globeMaterial = globe.globeMaterial();
  globeMaterial.color = new THREE.Color(0x3a228a);
  globeMaterial.emissive = new THREE.Color(0x220038);
  globeMaterial.emissiveIntensity = 0.1;
  globeMaterial.shininess = 0.7;
  return globe;
}

function initScene(globe, camera) {
  const scene = new THREE.Scene();
  scene.add(new THREE.AmbientLight(0xbbbbbb, 0.3));
  scene.background = new THREE.Color(0x040d21);
  scene.fog = new THREE.Fog(0x535ef3, 200, 2000);
  scene.add(camera);
  scene.add(globe);
  return scene;
}

function initCamera(width, height) {
  const camera = new THREE.PerspectiveCamera();
  camera.aspect = width / height;
  camera.updateProjectionMatrix();

  var dLight = new THREE.DirectionalLight(0xffffff, 10);
  dLight.position.set(-800, 2000, 400);
  camera.add(dLight);

  var dLight1 = new THREE.DirectionalLight(0x7982f6, 5);
  dLight1.position.set(-200, 500, 200);
  camera.add(dLight1);

  var dLight2 = new THREE.PointLight(0x8566cc, 15, 0, 0);
  dLight2.position.set(-200, 500, 200);
  camera.add(dLight2);

  camera.position.z = 300;
  camera.position.x = 0;
  camera.position.y = 0;
  return camera;
}

function initControls(camera, renderer) {
  const controls = new OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true;
  controls.dynamicDampingFactor = 0.01;
  controls.enablePan = false;
  controls.minDistance = 150;
  controls.maxDistance = 500;
  controls.rotateSpeed = 0.8;
  controls.zoomSpeed = 1;
  controls.autoRotate = false;

  controls.minPolarAngle = Math.PI / 3.5;
  controls.maxPolarAngle = Math.PI - Math.PI / 3;
  return controls;
}

export class Globe {
  constructor(elementId) {
    this.element = document.getElementById(elementId);
    this.labels = [];
    this.mouseX = 0;
    this.mouseY = 0;
    this.renderer = initRenderer(
      this.element.offsetWidth,
      this.element.offsetHeight
    );
    this.globe = initGlobe();
    this.camera = initCamera(
      this.element.offsetWidth,
      this.element.offsetHeight
    );
    this.controls = initControls(this.camera, this.renderer);
    this.scene = initScene(this.globe, this.camera);
    document.getElementById(elementId).appendChild(this.renderer.domElement);

    window.addEventListener("resize", () => this.updateSize(), false);
  }

  animate() {
    this.controls.update();
    this.renderer.render(this.scene, this.camera);
    requestAnimationFrame(() => this.animate());
  }

  setConnectedRegion(region) {
    for (const label of this.labels) {
      if (region && label.text.toLowerCase() === region.toLowerCase()) {
        label.connected = true;
        break;
      } else {
        label.connected = false;
      }
    }

    this.#updateArcs();
  }

  setStreamerRegion(region) {
    if (!region) return;

    for (const label of this.labels) {
      if (label.text.toLowerCase() === region.toLowerCase()) {
        label.streamer = true;
        // this will cause color update
        this.addLabels([label]);
        break;
      }
    }

    this.#updateArcs();
  }

  clearStreamerRegion() {
    for (const label of this.labels) {
      if (label.streamer) {
        label.streamer = false;
        // this will cause color update
        this.addLabels([label]);
        break;
      }
    }
  }

  addLabels(labels) {
    labels.forEach((label) => {
      const idx = this.labels.findIndex(
        (l) => l.lat === label.lat && l.lng === label.lng
      );

      // If there already is a label with the same lat and lng, replace it.
      // If there isn't, push it to the array of labels.
      if (idx === -1) {
        this.labels.push(label);
      } else {
        this.labels[idx] = label;
      }
    });

    this.globe
      .labelsData(this.labels)
      .labelColor((label) => {
        if (label.streamer) {
          return "#FF72A1";
        } else {
          return "#3AC2BE";
        }
      })
      .labelSize(2)
      .labelDotRadius(1.5)
      .labelText("text");

    this.#updateArcs();
  }

  #updateArcs() {
    const arcsData = [];
    const streamer = this.labels.find((label) => label.streamer === true);

    if (!streamer) return;

    const client = this.labels.find((label) => label.type === "client");

    this.labels.forEach((label) => {
      if (label.type !== "client") {
        // draw an arc from the streamer to a casual cluster
        if (!label.streamer) {
          const arc = {
            startLat: streamer.lat,
            startLng: streamer.lng,
            endLat: label.lat,
            endLng: label.lng,
          };

          const idx = this.globe
            .arcsData()
            .findIndex(
              (a) =>
                a.startLat === arc.startLat &&
                a.startLng === arc.startLng &&
                a.endLat === arc.endLat &&
                a.endLng === arc.endLng
            );

          // Push an arc only if it does not already exist.
          // Otherwise, use already existing arc.
          // This prevents from re-animating arc creation.
          if (idx === -1) {
            arcsData.push(arc);
          } else {
            arcsData.push(this.globe.arcsData()[idx]);
          }
        }

        // if this is the label we are connected to and there is
        // a label corresponding to our localization (client),
        // draw an arc from this label to us
        if (label.connected === true && client) {
          const arc = {
            startLat: label.lat,
            startLng: label.lng,
            endLat: client.lat,
            endLng: client.lng,
          };

          const idx = this.globe
            .arcsData()
            .findIndex(
              (a) =>
                a.startLat === arc.startLat &&
                a.startLng === arc.startLng &&
                a.endLat === arc.endLat &&
                a.endLng === arc.endLng
            );

          if (idx === -1) {
            arcsData.push(arc);
          } else {
            arcsData.push(this.globe.arcsData()[idx]);
          }
        }
      }
    });

    this.globe
      .arcsData(arcsData)
      .arcColor(() => "#3AC2BE")
      .arcStroke(2)
      .arcDashLength(0.02)
      .arcDashGap(0.01)
      .arcDashAnimateTime(10000);
  }

  removeArcs() {
    this.globe.arcsData([]);
  }

  updateSize() {
    this.camera.aspect = this.element.offsetWidth / this.element.offsetHeight;
    this.camera.updateProjectionMatrix();
    this.renderer.setSize(this.element.offsetWidth, this.element.offsetHeight);
  }
}
