defmodule TrackAnalyzerWeb.HealthControllerTest do
  use TrackAnalyzerWeb.ConnCase, async: true

  test "GET /health responds without touching the database", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert response(conn, 200) == "ok"
  end
end
