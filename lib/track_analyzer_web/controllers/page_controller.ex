defmodule TrackAnalyzerWeb.PageController do
  use TrackAnalyzerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
