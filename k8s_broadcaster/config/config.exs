# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :k8s_broadcaster,
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :k8s_broadcaster, K8sBroadcasterWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: K8sBroadcasterWeb.ErrorHTML, json: K8sBroadcasterWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: K8sBroadcaster.PubSub,
  live_view: [signing_salt: "2KRXfjle"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  k8s_broadcaster: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  k8s_broadcaster: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :mime, :types, %{
  "application/sdp" => ["sdp"],
  "application/trickle-ice-sdpfrag" => ["trickle-ice-sdpfrag"]
}

config :k8s_broadcaster,
  whip_token: "example",
  admin_username: "admin",
  admin_password: "admin"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
