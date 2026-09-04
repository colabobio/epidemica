defmodule EpidemicaServerWeb.Router do
  use EpidemicaServerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EpidemicaServerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :participant do
    plug EpidemicaServerWeb.Plugs.ParticipantToken
  end

  # The API version lives in the path prefix. The observation envelope and the payload contracts
  # version independently of it, so adding an observation type never requires an API release.
  scope "/v1", EpidemicaServerWeb do
    pipe_through :api

    get "/health", EnrollmentController, :health
    post "/enrollments", EnrollmentController, :create
    post "/tokens", EnrollmentController, :refresh
  end

  scope "/v1", EpidemicaServerWeb do
    pipe_through [:api, :participant]

    get "/studies/:id/protocol", ProtocolController, :show
    get "/instruments/:instrument_id/:version", InstrumentController, :show
    get "/participants/me/state", ParticipantStateController, :show
    post "/participants/me/actions", GameActionController, :create
    post "/observations", ObservationController, :create
    get "/observations/ack", ObservationController, :ack
  end

  scope "/", EpidemicaServerWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:epidemica_server, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: EpidemicaServerWeb.Telemetry
    end
  end
end
