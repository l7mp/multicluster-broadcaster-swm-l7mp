defmodule K8sBroadcasterWeb.MediaController do
  use K8sBroadcasterWeb, :controller

  alias K8sBroadcaster.{Forwarder, PeerSupervisor}
  alias ExWebRTC.PeerConnection

  @sse ~s/rel = "urn:ietf:params:whep:ext:core:server-sent-events"; events="layers"/
  @layer ~s/rel = "urn:ietf:params:whep:ext:core:layer"/

  plug(:accepts, ["sdp"] when action in [:whip, :whep])
  plug(:accepts, ["trickle-ice-sdpfrag"] when action in [:ice_candidate])

  # Used by Corsica in handling CORS requests: allows fetching response headers
  # by external WHEP players implemented in a browser.
  #
  # All headers used in the WHEP responses should be specified here
  def cors_expose_headers do
    ["location", "link", "content-type", "connection", "cache-control"]
  end

  def pc_config(conn, _params) do
    conn
    |> resp(200, K8sBroadcaster.PeerSupervisor.client_pc_config())
    |> send_resp()
  end

  def region(conn, %{"resourceId" => resource_id}) do
    case PeerSupervisor.fetch_pid(resource_id) do
      {:ok, pid} ->
        region = :erpc.call(node(pid), K8sBroadcaster, :get_region, []) || ""

        conn
        |> resp(200, region)
        |> send_resp()

      _ ->
        conn
        |> resp(404, "Resource id not found")
        |> send_resp()
    end
  end

  # TODO: use proper statuses in case of error
  def whip(conn, _params) do
    with {:ok, offer_sdp, conn} <- read_body(conn),
         {:ok, pc, pc_id, answer_sdp} <- PeerSupervisor.start_whip(offer_sdp),
         :ok <- Forwarder.connect_input(pc, pc_id) do
      conn
      |> put_resp_header("location", ~p"/api/resource/#{pc_id}")
      |> put_resp_content_type("application/sdp")
      |> resp(201, answer_sdp)
    else
      _other -> resp(conn, 400, "Bad request")
    end
    |> send_resp()
  end

  def whep(conn, _params) do
    # Allow not only for plain SDP but also for a JSON
    # with custom configuration options.
    decode_body = fn body ->
      case Jason.decode(body) do
        {:ok, %{"sdp" => _offer_sdp, "rtx" => _rtx}} = ret -> ret
        _ -> {:ok, %{"sdp" => body, "rtx" => true}}
      end
    end

    with {:ok, body, conn} <- read_body(conn),
         {:ok, %{"sdp" => offer_sdp, "rtx" => rtx}} <- decode_body.(body),
         {:ok, pc, pc_id, answer_sdp} <- PeerSupervisor.start_whep(offer_sdp, rtx),
         :ok <- Forwarder.connect_output(pc) do
      uri = ~p"/api/resource/#{pc_id}"

      conn
      |> put_resp_header("location", uri)
      # Plug does not allow adding multiple headers with the same name
      |> put_resp_header("link", "<#{uri}/layer>; " <> @layer)
      |> put_resp_header("link", "<#{uri}/sse>; " <> @sse)
      |> put_resp_content_type("application/sdp")
      |> resp(201, answer_sdp)
    else
      _other ->
        resp(conn, 400, "Bad request")
    end
    |> send_resp()
  end

  def ice_candidate(conn, %{"resource_id" => resource_id}) do
    with {:ok, pid} <- PeerSupervisor.fetch_pid(resource_id),
         {:ok, body, conn} <- read_body(conn),
         {:ok, json} <- Jason.decode(body) do
      candidate = ExWebRTC.ICECandidate.from_json(json)
      :ok = PeerConnection.add_ice_candidate(pid, candidate)
      resp(conn, 204, "")
    else
      _other -> resp(conn, 400, "Bad request")
    end
    |> send_resp()
  end

  def sse(conn, %{"resource_id" => resource_id}) do
    with {:ok, _pid} <- PeerSupervisor.fetch_pid(resource_id),
         {:ok, events} when is_list(events) <- Map.fetch(conn.body_params, "_json") do
      # for now, we just ignore events
      conn
      |> put_resp_header("location", ~p"/api/resource/#{resource_id}/sse/event-stream")
      |> resp(201, "")
    else
      _other -> resp(conn, 400, "Bad request")
    end
    |> send_resp()
  end

  def event_stream(conn, %{"resource_id" => resource_id}) do
    case PeerSupervisor.fetch_pid(resource_id) do
      {:ok, _pid} ->
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("connection", "keep-alive")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)
        |> update_layers()

      {:error, :peer_not_found} ->
        send_resp(conn, 400, "Bad request")
    end
  end

  def layer(conn, %{"resource_id" => resource_id}) do
    with {:ok, pid} <- PeerSupervisor.fetch_pid(resource_id),
         :ok <- Forwarder.set_layer(pid, conn.body_params["encodingId"]) do
      resp(conn, 200, "")
    else
      _other ->
        resp(conn, 400, "Bad reqeust")
    end
    |> send_resp()
  end

  def remove_pc(conn, %{"resource_id" => resource_id}) do
    case PeerSupervisor.fetch_pid(resource_id) do
      {:ok, pid} ->
        PeerSupervisor.terminate_pc(pid)
        resp(conn, 200, "")

      _other ->
        resp(conn, 400, "Bad request")
    end
    |> send_resp()
  end

  defp update_layers(conn) do
    case Forwarder.get_layers() do
      {:ok, layers} ->
        data = Jason.encode!(%{layers: layers})
        chunk(conn, ~s/data: #{data}\n\n/)

        Process.send_after(self(), :layers, 2000)

        receive do
          :layers -> update_layers(conn)
        end

      :error ->
        conn
    end
  end
end
