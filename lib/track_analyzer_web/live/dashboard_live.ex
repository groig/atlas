defmodule TrackAnalyzerWeb.DashboardLive do
  use TrackAnalyzerWeb, :live_view

  alias TrackAnalyzer.{Imports, Tracks}
  alias TrackAnalyzer.Tracks.RouteProgress

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Tracks.subscribe()
      Imports.subscribe()
      RouteProgress.subscribe()
    end

    tracks = Tracks.list_tracks() |> Enum.take(8)
    archives = Imports.list_recent_archives(4)

    {:ok,
     socket
     |> assign(:page_title, "Overview")
     |> assign(:share_open?, false)
     |> assign_dashboard()
     |> stream(:recent_tracks, tracks)
     |> stream(:active_imports, archives)}
  end

  @impl true
  def handle_event("open_share", _params, socket) do
    {:noreply, assign(socket, :share_open?, true)}
  end

  def handle_event("close_share", _params, socket) do
    {:noreply, assign(socket, :share_open?, false)}
  end

  def handle_event("share_summary", %{"period" => "all"}, socket) do
    {:reply, %{ok: true, summary: Tracks.share_summary(:all)}, socket}
  end

  def handle_event(
        "share_summary",
        %{"period" => period, "from" => from_iso, "until" => until_iso},
        socket
      )
      when period in ~w(week month year) do
    with {:ok, from, _offset} <- DateTime.from_iso8601(from_iso),
         {:ok, until, _offset} <- DateTime.from_iso8601(until_iso),
         :lt <- DateTime.compare(from, until),
         true <- valid_share_window?(period, DateTime.diff(until, from)) do
      summary = Tracks.share_summary(%{from: from, until: until})
      {:reply, %{ok: true, summary: summary}, socket}
    else
      _error -> {:reply, %{ok: false, error: "Could not load that calendar period."}, socket}
    end
  end

  def handle_event("share_summary", _params, socket) do
    {:reply, %{ok: false, error: "Choose a valid recap period."}, socket}
  end

  @impl true
  def handle_info({:track_updated, track}, socket) do
    {:noreply, socket |> assign_dashboard() |> stream_insert(:recent_tracks, track, at: 0)}
  end

  def handle_info({:archive_updated, archive}, socket) do
    {:noreply, stream_insert(socket, :active_imports, archive, at: 0)}
  end

  def handle_info({:batch_updated, _batch}, socket), do: {:noreply, socket}

  def handle_info({:route_progress_rebuilt, _result}, socket),
    do: {:noreply, assign_dashboard(socket)}

  defp valid_share_window?("week", seconds), do: seconds in (6 * 86_400)..(8 * 86_400)
  defp valid_share_window?("month", seconds), do: seconds in (27 * 86_400)..(32 * 86_400)
  defp valid_share_window?("year", seconds), do: seconds in (364 * 86_400)..(367 * 86_400)

  defp assign_dashboard(socket) do
    summary = Tracks.portfolio_summary()
    speed_summary = Tracks.speed_history(%{"metric" => "100m", "range" => "all"})
    progress_summary = RouteProgress.summary()
    cells = Tracks.heatmap_cells(3_000)

    socket
    |> assign(:summary, summary)
    |> assign(:latest_track, Tracks.latest_complete_track())
    |> assign(:speed_summary, speed_summary)
    |> assign(:progress_summary, progress_summary)
    |> assign(:monthly_json, json(summary.monthly))
    |> assign(:cells_json, json(cells))
    |> assign(:has_map?, cells != [])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil} active="overview">
      <section
        id="dashboard-summary"
        class="relative overflow-hidden rounded-[1.7rem] border border-white/8 bg-[var(--hero)] px-5 py-5 text-[var(--hero-ink)] shadow-xl sm:px-7 sm:py-6"
      >
        <div class="contour-pattern absolute inset-0 opacity-25"></div>
        <div class="relative grid gap-5 lg:grid-cols-[0.75fr_1.25fr] lg:items-center">
          <div>
            <div class="flex flex-wrap items-center gap-3">
              <h1 class="text-3xl font-black tracking-[-0.045em] sm:text-4xl">Overview</h1>
              <button
                id="open-share-recap"
                type="button"
                phx-click="open_share"
                disabled={@summary.track_count == 0}
                class="inline-flex min-h-10 items-center gap-2 rounded-xl bg-[var(--accent)] px-3.5 text-sm font-black text-[var(--accent-ink)] shadow-sm transition hover:-translate-y-0.5 disabled:cursor-not-allowed disabled:opacity-45"
              >
                <.icon name="hero-share" class="size-4" /> Create recap
              </button>
            </div>
            <p class="mt-2 max-w-md text-sm leading-6 text-white/58">
              Analyzed OsmAnd tracks and current processing state.
            </p>
          </div>
          <div class="grid gap-2 sm:grid-cols-3">
            <.link
              :if={@latest_track}
              id="latest-analyzed-track"
              navigate={~p"/tracks/#{@latest_track.id}"}
              class="group rounded-2xl border border-white/12 bg-white/7 px-4 py-3 transition hover:-translate-y-0.5 hover:bg-white/11 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--accent)]"
            >
              <p class="text-[10px] font-bold uppercase tracking-[0.15em] text-white/45">
                Latest analyzed
              </p>
              <div class="mt-1.5 flex items-center justify-between gap-2">
                <div class="min-w-0">
                  <p class="truncate text-sm font-bold">{@latest_track.name}</p>
                  <p class="mt-0.5 text-xs text-white/48">{short_date(@latest_track.started_at)}</p>
                </div>
                <.icon
                  name="hero-arrow-up-right"
                  class="size-4 shrink-0 text-[var(--accent)] transition group-hover:-translate-y-0.5 group-hover:translate-x-0.5"
                />
              </div>
            </.link>
            <div
              :if={!@latest_track}
              id="latest-analyzed-track-empty"
              class="rounded-2xl border border-white/12 bg-white/7 px-4 py-3"
            >
              <p class="text-[10px] font-bold uppercase tracking-[0.15em] text-white/45">
                Latest analyzed
              </p>
              <p class="mt-1.5 text-sm font-bold">No analyzed tracks</p>
              <p class="mt-0.5 text-xs text-white/48">Waiting for an import</p>
            </div>
            <div
              id="library-date-span"
              class="rounded-2xl border border-white/12 bg-white/7 px-4 py-3"
            >
              <p class="text-[10px] font-bold uppercase tracking-[0.15em] text-white/45">
                Library span
              </p>
              <p class="mt-1.5 text-sm font-bold">{short_date(@summary.earliest_at)}</p>
              <p class="mt-0.5 text-xs text-white/48">to {short_date(@summary.latest_at)}</p>
            </div>
            <div id="analyzer-state" class="rounded-2xl border border-white/12 bg-white/7 px-4 py-3">
              <p class="text-[10px] font-bold uppercase tracking-[0.15em] text-white/45">
                Analyzer
              </p>
              <div class="mt-1.5 flex items-center gap-2">
                <span class={[
                  "size-2 rounded-full",
                  if(@summary.processing_count > 0,
                    do: "bg-[var(--accent)] shadow-[0_0_12px_var(--accent)]",
                    else: "bg-emerald-400"
                  )
                ]}></span>
                <p class="text-sm font-bold">
                  {if(@summary.processing_count > 0,
                    do: "#{@summary.processing_count} processing",
                    else: "Idle"
                  )}
                </p>
              </div>
              <p class="mt-0.5 text-xs text-white/48">Background analysis</p>
            </div>
          </div>
        </div>
      </section>

      <.link
        id="dashboard-progress-pulse"
        navigate={~p"/progress"}
        class="group mt-5 grid gap-4 rounded-[1.7rem] border border-[var(--line)] bg-[var(--surface)] p-5 shadow-[var(--shadow)] transition hover:-translate-y-0.5 sm:grid-cols-[1fr_auto] sm:items-center sm:px-6"
      >
        <div class="flex items-center gap-4">
          <span class="grid size-12 shrink-0 place-items-center rounded-2xl bg-[var(--accent)] text-[var(--accent-ink)] transition group-hover:rotate-3">
            <.icon name="hero-arrow-trending-up" class="size-6" />
          </span>
          <div>
            <p class="text-[10px] font-bold uppercase tracking-[0.16em] text-[var(--ink-muted)]">
              Progress pulse
            </p>
            <h2 class="mt-1 text-xl font-black tracking-[-0.035em]">
              {@progress_summary.cluster_count} repeated routes · {@progress_summary.improving_count} faster signals
            </h2>
            <p class="mt-1 text-xs text-[var(--ink-muted)] sm:text-sm">
              Compare like-for-like attempts, route sectors, weekly volume, and sustained efforts.
            </p>
          </div>
        </div>
        <span class="inline-flex items-center gap-2 text-sm font-black">
          Open progress
          <.icon name="hero-arrow-right" class="size-4 transition group-hover:translate-x-1" />
        </span>
      </.link>

      <section id="portfolio-metrics" class="mt-5 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.metric_card
          label="Distance mapped"
          value={distance(@summary.distance_m)}
          note={"across #{@summary.track_count} tracks"}
          icon="hero-map"
        />
        <.metric_card
          label="Time in motion"
          value={duration(@summary.moving_s)}
          note="stops excluded"
          icon="hero-clock"
        />
        <.metric_card
          label="Vertical earned"
          value={elevation(@summary.elevation_gain_m)}
          note="noise-filtered ascent"
          icon="hero-arrow-trending-up"
        />
        <.metric_card
          label="Route detail"
          value={compact_number(@summary.point_count)}
          note={"#{compact_number(@summary.unique_route_cells)} mapped cells"}
          icon="hero-sparkles"
        />
      </section>

      <section
        id="speed-lab-teaser"
        class="mt-5 grid overflow-hidden rounded-[1.7rem] bg-[var(--accent)] text-[var(--accent-ink)] shadow-lg lg:grid-cols-[1fr_auto]"
      >
        <.link
          navigate={~p"/speed"}
          id="speed-history-link"
          class="group flex items-center gap-4 px-5 py-5 transition hover:bg-black/5 focus-visible:outline-2 focus-visible:outline-offset-[-3px] focus-visible:outline-[var(--accent-ink)] sm:px-7"
        >
          <span class="grid size-12 shrink-0 place-items-center rounded-2xl bg-black/8 transition group-hover:rotate-3"><.icon
            name="hero-bolt"
            class="size-6"
          /></span>
          <div class="min-w-0 flex-1">
            <p class="text-[10px] font-bold uppercase tracking-[0.16em] opacity-55">Speed history</p>
            <h2 class="mt-1 text-xl font-black tracking-[-0.035em] sm:text-2xl">
              Records and historical behavior
            </h2>
            <p class="mt-1 text-xs opacity-60 sm:text-sm">
              Instantaneous peaks, sustained efforts, confidence, and progression over time.
            </p>
          </div>
          <.icon
            name="hero-arrow-right"
            class="hidden size-5 shrink-0 transition group-hover:translate-x-1 sm:block"
          />
        </.link>
        <div class="grid grid-cols-3 border-t border-black/10 lg:border-l lg:border-t-0">
          <.speed_teaser_metric
            id="dashboard-record-100m"
            label="100 m best"
            record={@speed_summary.records.best_100m}
            value={
              speed(@speed_summary.records.best_100m && @speed_summary.records.best_100m.speed_mps)
            }
          />
          <.speed_teaser_metric
            id="dashboard-record-500m"
            label="500 m best"
            record={@speed_summary.records.best_500m}
            value={
              speed(@speed_summary.records.best_500m && @speed_summary.records.best_500m.speed_mps)
            }
          />
          <.speed_teaser_metric
            id="dashboard-record-instantaneous"
            label="Peak"
            record={@speed_summary.records.instantaneous}
            value={
              speed(
                @speed_summary.records.instantaneous && @speed_summary.records.instantaneous.speed_mps
              )
            }
          />
        </div>
      </section>

      <section class="mt-5 grid gap-5 xl:grid-cols-[1.45fr_0.75fr]">
        <div id="route-atlas-card" class="topo-card overflow-hidden rounded-[1.7rem]">
          <div class="flex items-start justify-between gap-4 px-5 py-5 sm:px-6">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                Portfolio heatmap
              </p>
              <h2 class="mt-1 text-xl font-black tracking-[-0.035em]">Where your tracks overlap</h2>
            </div>
            <.link
              navigate={~p"/explore"}
              class="text-sm font-bold text-[var(--ink-muted)] transition hover:text-[var(--ink)]"
            >Explore →</.link>
          </div>
          <div
            :if={@has_map?}
            id="dashboard-heatmap"
            phx-hook="HeatMap"
            phx-update="ignore"
            data-cells={@cells_json}
            data-tile-url={Application.fetch_env!(:track_analyzer, :maps)[:tile_url]}
            data-attribution={Application.fetch_env!(:track_analyzer, :maps)[:attribution]}
            class="h-[27rem] border-t border-[var(--line)]"
          >
          </div>
          <div
            :if={!@has_map?}
            id="dashboard-map-empty"
            class="contour-pattern grid h-[27rem] place-items-center border-t border-[var(--line)] px-6 text-center"
          >
            <div class="max-w-sm">
              <span class="mx-auto grid size-14 place-items-center rounded-2xl bg-[var(--accent)] text-[var(--accent-ink)]"><.icon
                name="hero-map"
                class="size-7"
              /></span>
              <h3 class="mt-4 text-lg font-black">No route coverage yet</h3>
              <p class="mt-2 text-sm leading-6 text-[var(--ink-muted)]">
                The combined heatmap appears after an OsmAnd export is analyzed.
              </p>
            </div>
          </div>
        </div>

        <div class="topo-card rounded-[1.7rem] p-5 sm:p-6">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                Rhythm
              </p>
              <h2 class="mt-1 text-xl font-black tracking-[-0.035em]">Monthly distance</h2>
            </div>
            <span class="grid size-10 place-items-center rounded-xl bg-[var(--accent)] text-[var(--accent-ink)]"><.icon
              name="hero-chart-bar"
              class="size-5"
            /></span>
          </div>
          <div
            :if={@summary.monthly != []}
            id="monthly-distance-chart"
            phx-hook="MonthlyChart"
            phx-update="ignore"
            data-monthly={@monthly_json}
            class="echarts-surface mt-5"
          >
          </div>
          <div
            :if={@summary.monthly == []}
            id="monthly-chart-empty"
            class="grid min-h-72 place-items-center text-center text-sm text-[var(--ink-muted)]"
          >
            Trends will appear after analysis.
          </div>
          <div class="mt-3 grid grid-cols-2 gap-3 border-t border-[var(--line)] pt-4">
            <div>
              <p class="text-xs text-[var(--ink-muted)]">Data quality</p><p class="metric-number mt-1 text-2xl font-black">
                {percent(@summary.quality_score)}
              </p>
            </div>
            <div>
              <p class="text-xs text-[var(--ink-muted)]">Date span</p><p class="mt-1 text-sm font-bold">
                {short_date(@summary.earliest_at)}<br />to {short_date(@summary.latest_at)}
              </p>
            </div>
          </div>
        </div>
      </section>

      <section class="mt-5 grid gap-5 xl:grid-cols-[1fr_0.72fr]">
        <div class="topo-card rounded-[1.7rem] p-5 sm:p-6">
          <div class="mb-4 flex items-center justify-between">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                Freshly analyzed
              </p><h2 class="mt-1 text-xl font-black tracking-[-0.035em]">Recent tracks</h2>
            </div>
            <.link
              navigate={~p"/tracks"}
              class="text-sm font-bold text-[var(--ink-muted)] hover:text-[var(--ink)]"
            >All tracks →</.link>
          </div>
          <div id="recent-tracks" phx-update="stream" class="divide-y divide-[var(--line)]">
            <div
              id="recent-tracks-empty"
              class="hidden only:block rounded-2xl border border-dashed border-[var(--line)] px-5 py-10 text-center text-sm text-[var(--ink-muted)]"
            >
              No tracks yet. Your first import will show up here.
            </div>
            <.link
              :for={{id, track} <- @streams.recent_tracks}
              id={id}
              navigate={~p"/tracks/#{track.id}"}
              class="group grid grid-cols-[1fr_auto] items-center gap-4 py-4 first:pt-1 last:pb-1"
            >
              <div class="min-w-0">
                <p class="truncate font-bold tracking-[-0.015em] group-hover:underline">
                  {track.name}
                </p><p class="mt-1 text-xs text-[var(--ink-muted)]">
                  {short_date(track.started_at)} · {track.point_count} points · {status_label(
                    track.status
                  )}
                </p>
              </div>
              <div class="text-right">
                <p class="metric-number font-black">{distance(track.distance_m)}</p><p class="mt-1 text-xs text-[var(--ink-muted)]">
                  {speed(track.avg_speed_mps)} avg
                </p>
              </div>
            </.link>
          </div>
        </div>

        <div class="topo-card rounded-[1.7rem] p-5 sm:p-6">
          <div class="mb-4">
            <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
              Processing dock
            </p><h2 class="mt-1 text-xl font-black tracking-[-0.035em]">OSF imports</h2>
          </div>
          <div id="dashboard-imports" phx-update="stream" class="space-y-3">
            <div
              id="dashboard-imports-empty"
              class="hidden only:block rounded-2xl border border-dashed border-[var(--line)] px-5 py-10 text-center text-sm text-[var(--ink-muted)]"
            >
              No exports uploaded yet.
            </div>
            <div
              :for={{id, archive} <- @streams.active_imports}
              id={id}
              class="rounded-2xl border border-[var(--line)] bg-[var(--surface-strong)] p-4"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="truncate text-sm font-bold">{archive.original_filename}</p><p class="mt-1 text-xs text-[var(--ink-muted)]">
                    {archive.stage}
                  </p>
                </div><span class={[
                  "rounded-full px-2 py-1 text-[10px] font-bold uppercase tracking-wider ring-1",
                  status_classes(archive.status)
                ]}>{archive.progress}%</span>
              </div>
              <div class="mt-3 h-1.5 overflow-hidden rounded-full bg-[var(--line)]">
                <div
                  class="h-full rounded-full bg-[var(--accent-strong)] transition-all duration-500"
                  style={"width: #{archive.progress}%"}
                >
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <div
        :if={@share_open?}
        id="share-recap-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="share-recap-title"
        phx-window-keydown="close_share"
        phx-key="escape"
        class="fixed inset-0 z-[1200] grid place-items-center overflow-y-auto p-3 sm:p-6"
      >
        <button
          id="share-recap-backdrop"
          type="button"
          phx-click="close_share"
          class="fixed inset-0 cursor-default bg-black/68 backdrop-blur-md"
          aria-label="Close recap creator"
        ></button>

        <section class="topo-card relative my-auto w-full max-w-6xl overflow-hidden rounded-[2rem] bg-[var(--canvas-raised)] shadow-2xl">
          <header class="flex items-start justify-between gap-5 border-b border-[var(--line)] px-5 py-4 sm:px-7 sm:py-5">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                Story maker
              </p>
              <h2 id="share-recap-title" class="mt-1 text-2xl font-black tracking-[-0.04em]">
                Create a track recap
              </h2>
              <p class="mt-1 max-w-xl text-sm leading-6 text-[var(--ink-muted)]">
                A private 9:16 summary built locally for Stories and Status.
              </p>
            </div>
            <button
              id="close-share-recap"
              type="button"
              phx-click="close_share"
              class="grid size-10 shrink-0 place-items-center rounded-xl border border-[var(--line)] bg-[var(--surface-strong)] text-[var(--ink-muted)] transition hover:text-[var(--ink)]"
              aria-label="Close recap creator"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </header>

          <div
            id="share-card-generator"
            class="grid max-h-[calc(100vh-8rem)] overflow-y-auto lg:grid-cols-[minmax(0,0.88fr)_minmax(21rem,0.62fr)]"
          >
            <div class="order-2 flex flex-col p-5 sm:p-7 lg:order-1">
              <div>
                <p class="text-xs font-bold uppercase tracking-[0.14em] text-[var(--ink-muted)]">
                  Recap period
                </p>
                <div
                  id="share-recap-periods"
                  class="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4 lg:grid-cols-2"
                >
                  <button
                    :for={
                      period <- [
                        %{value: "all", label: "All time"},
                        %{value: "year", label: "This year"},
                        %{value: "month", label: "This month"},
                        %{value: "week", label: "This week"}
                      ]
                    }
                    id={"share-period-#{period.value}"}
                    type="button"
                    data-share-period={period.value}
                    aria-pressed={to_string(period.value == "year")}
                    class="min-h-11 rounded-xl border border-[var(--line)] bg-[var(--surface-strong)] px-3 text-sm font-bold transition hover:border-[var(--ink-muted)] aria-pressed:border-[var(--ink)] aria-pressed:bg-[var(--ink)] aria-pressed:text-[var(--canvas)]"
                  >
                    {period.label}
                  </button>
                </div>
              </div>

              <div class="mt-6 rounded-2xl border border-[var(--line)] bg-[var(--surface-strong)] p-4">
                <div class="flex items-start gap-3">
                  <span class="grid size-10 shrink-0 place-items-center rounded-xl bg-[color-mix(in_srgb,var(--accent)_28%,transparent)]">
                    <.icon name="hero-shield-check" class="size-5" />
                  </span>
                  <div>
                    <p class="text-sm font-black">Aggregate-only by design</p>
                    <p class="mt-1 text-xs leading-5 text-[var(--ink-muted)]">
                      No route, coordinates, map, track names, filenames, or exact activity times are placed in the image.
                    </p>
                  </div>
                </div>
              </div>

              <div class="mt-6">
                <p
                  id="share-recap-status"
                  class="min-h-6 text-sm text-[var(--ink-muted)]"
                  aria-live="polite"
                >
                  Building this year's recap…
                </p>
                <div class="mt-3 flex flex-wrap gap-3">
                  <button
                    id="share-recap-share"
                    type="button"
                    disabled
                    class="hidden min-h-11 items-center justify-center gap-2 rounded-xl bg-[var(--accent)] px-4 py-2 text-sm font-black text-[var(--accent-ink)] shadow-sm transition hover:-translate-y-0.5 disabled:cursor-not-allowed disabled:opacity-45"
                  >
                    <.icon name="hero-share" class="size-4" /> Share image
                  </button>
                  <button
                    id="share-recap-download"
                    type="button"
                    disabled
                    class="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-[var(--ink)] px-4 py-2 text-sm font-black text-[var(--canvas)] shadow-sm transition hover:-translate-y-0.5 disabled:cursor-not-allowed disabled:opacity-45"
                  >
                    <.icon name="hero-arrow-down-tray" class="size-4" /> Download PNG
                  </button>
                </div>
              </div>

              <p class="mt-auto pt-7 text-xs leading-5 text-[var(--ink-muted)]">
                The image is rendered in this browser and is never saved by Track / Atlas.
              </p>
            </div>

            <div class="order-1 border-b border-[var(--line)] bg-[var(--canvas)] p-5 sm:p-7 lg:order-2 lg:border-b-0 lg:border-l">
              <div
                id="share-story-preview"
                class="relative mx-auto w-full max-w-[23rem] overflow-hidden rounded-[1.8rem] shadow-2xl ring-1 ring-black/10"
              >
                <canvas
                  id="share-card-canvas"
                  phx-hook="ShareCard"
                  phx-update="ignore"
                  data-default-period="year"
                  width="1080"
                  height="1920"
                  class="block aspect-[9/16] w-full bg-[#0c1310]"
                  role="img"
                  aria-label="Track recap image preview"
                >
                  Track recap image preview
                </canvas>
                <div
                  id="share-card-loading"
                  class="absolute inset-0 grid place-items-center bg-[#0c1310]/88 text-white backdrop-blur-sm"
                >
                  <div class="text-center">
                    <span class="mx-auto block size-8 animate-spin rounded-full border-2 border-white/20 border-t-[#d8ff45]"></span>
                    <p class="mt-3 text-xs font-bold uppercase tracking-[0.16em] text-white/60">
                      Composing recap
                    </p>
                  </div>
                </div>
              </div>
              <p class="mt-3 text-center text-xs text-[var(--ink-muted)]">
                1080 × 1920 PNG · 9:16
              </p>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, required: true
  attr :icon, :string, required: true

  defp metric_card(assigns) do
    ~H"""
    <article class="topo-card group rounded-[1.45rem] p-4 transition duration-200 hover:-translate-y-1 sm:p-5">
      <div class="flex items-start justify-between gap-3">
        <p class="text-xs font-bold uppercase tracking-[0.13em] text-[var(--ink-muted)]">{@label}</p><span class="grid size-9 place-items-center rounded-xl bg-[color-mix(in_srgb,var(--accent)_25%,transparent)] text-[var(--ink)] transition group-hover:bg-[var(--accent)]"><.icon
          name={@icon}
          class="size-4"
        /></span>
      </div>
      <p class="metric-number mt-5 text-3xl font-black leading-none sm:text-4xl">{@value}</p>
      <p class="mt-2 text-xs text-[var(--ink-muted)]">{@note}</p>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :record, :map, default: nil

  defp speed_teaser_metric(assigns) do
    ~H"""
    <.link
      :if={@record}
      id={@id}
      navigate={~p"/tracks/#{@record.track_id}"}
      aria-label={"Open #{@label} source track #{@record.name}"}
      class="group flex min-w-0 items-center justify-center border-r border-black/10 px-2 py-4 text-center transition last:border-r-0 hover:bg-black/6 focus-visible:outline-2 focus-visible:outline-offset-[-3px] focus-visible:outline-[var(--accent-ink)] sm:min-w-36 sm:px-4 lg:py-5"
    >
      <div class="min-w-0">
        <p class="text-[9px] font-bold uppercase tracking-[0.12em] opacity-50">{@label}</p>
        <p class="metric-number mt-1 whitespace-nowrap text-base font-black sm:text-xl">
          {@value}<.icon
            name="hero-arrow-up-right"
            class="ml-0.5 inline size-3.5 transition group-hover:-translate-y-0.5 group-hover:translate-x-0.5 sm:size-4"
          />
        </p>
        <p class="mt-0.5 truncate text-[9px] opacity-50 sm:text-[10px]">{@record.name}</p>
      </div>
    </.link>
    <div
      :if={!@record}
      id={@id}
      class="flex min-w-0 items-center justify-center border-r border-black/10 px-2 py-4 text-center last:border-r-0 sm:min-w-36 sm:px-4 lg:py-5"
    >
      <div>
        <p class="text-[9px] font-bold uppercase tracking-[0.12em] opacity-50">{@label}</p>
        <p class="metric-number mt-1 whitespace-nowrap text-base font-black sm:text-xl">{@value}</p>
        <p class="mt-0.5 text-[9px] opacity-50 sm:text-[10px]">No qualified effort</p>
      </div>
    </div>
    """
  end
end
