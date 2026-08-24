defmodule TrackAnalyzer.Repo do
  use Ecto.Repo,
    otp_app: :track_analyzer,
    adapter: Ecto.Adapters.Postgres
end
