defmodule K8sBroadcasterWeb.Router do
  use K8sBroadcasterWeb, :router

  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {K8sBroadcasterWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :admin_auth do
    plug :authenticate_admin
  end

  pipeline :api_auth do
    plug :authenticate_api
  end

  scope "/", K8sBroadcasterWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api", K8sBroadcasterWeb do
    get "/pc-config", MediaController, :pc_config
    get "/region", MediaController, :region
    post "/whep", MediaController, :whep

    scope "/resource/:resource_id" do
      patch "/", MediaController, :ice_candidate
      delete "/", MediaController, :remove_pc
      get "/sse/event-stream", MediaController, :event_stream
      post "/sse", MediaController, :sse
      post "/layer", MediaController, :layer
    end
  end

  scope "/api", K8sBroadcasterWeb do
    pipe_through :api_auth

    post "/whip", MediaController, :whip
    post "/server-stream", PageController, :toggle_server_stream
  end

  scope "/admin", K8sBroadcasterWeb do
    pipe_through :admin_auth
    pipe_through :browser

    get "/panel", PageController, :panel

    live_dashboard "/dashboard",
      metrics: K8sBroadcasterWeb.Telemetry,
      additional_pages: [exwebrtc: ExWebRTCDashboard]
  end

  def cors_expose_headers, do: K8sBroadcasterWeb.MediaController.cors_expose_headers()

  defp authenticate_api(conn, _opts) do
    valid_token = Application.fetch_env!(:k8s_broadcaster, :whip_token)

    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- token == valid_token do
      conn
    else
      _other -> resp(conn, 401, "Unauthorized") |> halt()
    end
  end

  defp authenticate_admin(conn, _opts) do
    username = Application.fetch_env!(:k8s_broadcaster, :admin_username)
    password = Application.fetch_env!(:k8s_broadcaster, :admin_password)
    Plug.BasicAuth.basic_auth(conn, username: username, password: password)
  end
end
