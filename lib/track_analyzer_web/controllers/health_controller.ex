defmodule TrackAnalyzerWeb.HealthController do
  @moduledoc """
  Liveness endpoint for container health checks.

  Deliberately does not touch the database: every other route is a LiveView
  behind the `:browser` pipeline that mounts and queries, which makes for a
  health check that fails whenever the library is merely busy.
  """

  use TrackAnalyzerWeb, :controller

  def show(conn, _params), do: send_resp(conn, 200, "ok")
end
