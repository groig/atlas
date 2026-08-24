defmodule TrackAnalyzerWeb.Router do
  use TrackAnalyzerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TrackAnalyzerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TrackAnalyzerWeb do
    pipe_through :browser

    live "/", DashboardLive
    live "/import", ImportLive
    live "/tracks", TrackIndexLive
    live "/tracks/:id", TrackShowLive
    live "/speed", SpeedLive
    live "/explore", ExploreLive
    live "/compare", CompareLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", TrackAnalyzerWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:track_analyzer, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TrackAnalyzerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
