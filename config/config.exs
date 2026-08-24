# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :mime, :types, %{
  "application/vnd.osmand.osf" => ["osf"]
}

config :track_analyzer,
  ecto_repos: [TrackAnalyzer.Repo],
  generators: [timestamp_type: :utc_datetime]

config :track_analyzer, TrackAnalyzer.Storage.Local,
  root: Path.expand("../var/track_analyzer", __DIR__)

config :track_analyzer, Oban,
  repo: TrackAnalyzer.Repo,
  plugins: [{Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}],
  queues: [archives: 1, analysis: 4, enrichment: 1, maintenance: 1]

config :track_analyzer, :analysis,
  moving_threshold_mps: 2.0 / 3.6,
  stop_minimum_seconds: 30,
  grade_window_m: 100,
  elevation_noise_floor_m: 3.0,
  max_plausible_speed_mps: 150.0 / 3.6

config :track_analyzer, :maps,
  tile_url: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
  attribution:
    "&copy; <a href=\"https://www.openstreetmap.org/copyright\">OpenStreetMap</a> contributors"

config :track_analyzer, :enrichments,
  enabled: false,
  user_agent: "TrackAnalyzer/0.1 (local personal application)",
  nominatim_url: "https://nominatim.openstreetmap.org",
  open_meteo_archive_url: "https://archive-api.open-meteo.com/v1/archive",
  open_meteo_elevation_url: "https://api.open-meteo.com/v1/elevation"

# Configure the endpoint
config :track_analyzer, TrackAnalyzerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TrackAnalyzerWeb.ErrorHTML, json: TrackAnalyzerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TrackAnalyzer.PubSub,
  live_view: [signing_salt: "PSZhJ9se"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :track_analyzer, TrackAnalyzer.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  track_analyzer: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  track_analyzer: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
