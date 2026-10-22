defmodule TrackAnalyzerWeb.PedalingLive do
  use TrackAnalyzerWeb, :live_view

  import TrackAnalyzerWeb.HeartRateComponents, only: [progress_tabs: 1]
  import TrackAnalyzerWeb.SensorComponents

  alias TrackAnalyzer.Tracks
  alias TrackAnalyzer.Tracks.Pedaling

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Tracks.subscribe()
    {:ok, socket |> assign(:page_title, "Pedaling · Progress") |> load()}
  end

  @impl true
  def handle_event("upgrade_analysis", _params, socket) do
    {:ok, result} = Tracks.enqueue_stale_analyses()

    {:noreply,
     socket
     |> load()
     |> put_flash(
       :info,
       "Queued #{result.enqueued_count} tracks. Sensor data appears as analysis finishes."
     )}
  end

  @impl true
  def handle_info({:track_updated, %{status: "complete"}}, socket), do: {:noreply, load(socket)}
  def handle_info({:track_updated, _track}, socket), do: {:noreply, socket}

  defp load(socket) do
    overview = Pedaling.overview()

    socket
    |> assign(:summary, Map.drop(overview, [:tracks]))
    |> assign(:stale_count, Tracks.stale_analysis_count())
    |> stream(:sensor_tracks, overview.tracks, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil} active="progress">
      <article id="pedaling-progress" class="space-y-5">
        <header class="relative overflow-hidden rounded-[1.7rem] bg-[var(--hero)] p-6 text-[var(--hero-ink)] sm:p-8">
          <div class="contour-pattern pointer-events-none absolute inset-0 opacity-20"></div>
          <div class="relative">
            <p class="flex items-center gap-2 text-xs font-bold uppercase tracking-[0.17em] text-[#ad9cff]">
              <.icon name="hero-arrow-path" class="size-4" />Progress
            </p>
            <h1 class="mt-2 text-3xl font-black tracking-tight sm:text-4xl">Pedaling & sensors</h1>
            <p class="mt-3 max-w-2xl text-sm leading-6 text-white/65">
              How you turn the pedals across rides: cadence, coasting, the gears you favour, and whether your speed sensor agrees with GPS.
            </p>
          </div>
        </header>

        <.progress_tabs active="pedaling" />

        <div
          :if={@stale_count > 0}
          id="pedaling-upgrade-banner"
          class="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-[var(--line)] p-4 text-sm"
        >
          <p>{@stale_count} older analyses can be checked for cadence and speed sensor data.</p>
          <.button id="pedaling-upgrade-analysis" phx-click="upgrade_analysis">
            Update analyses
          </.button>
        </div>

        <div
          :if={@summary.count == 0}
          id="pedaling-empty"
          class="topo-card rounded-[1.7rem] p-8 text-center"
        >
          <.icon name="hero-arrow-path" class="size-9 text-[var(--cadence)]" />
          <h2 class="mt-3 text-xl font-black">No sensor recordings yet</h2>
          <p class="mx-auto mt-3 max-w-xl text-sm leading-6 text-[var(--ink-muted)]">
            Upload a .fit file from a bike computer or app, or a GPX with cadence extensions, recorded with a cadence or speed sensor paired. Rides without sensors keep their usual analysis.
          </p>
          <.link
            navigate={~p"/import"}
            class="mt-5 inline-flex min-h-11 items-center gap-2 text-sm font-bold"
          >Import a ride <.icon name="hero-arrow-right" class="size-4" /></.link>
        </div>

        <dl
          :if={@summary.cadence_count > 0}
          id="pedaling-summary"
          class="grid grid-cols-2 gap-3 lg:grid-cols-4"
        >
          <.sensor_stat
            label="Rides with cadence"
            value={to_string(@summary.cadence_count)}
            note={"#{duration(@summary.pedaling_s)} pedaling"}
          />
          <.sensor_stat
            label="Average cadence"
            value={rpm(@summary.average_rpm)}
            note="pedaling time, all rides"
          />
          <.sensor_stat
            label="Coasting"
            value={percent(@summary.coasting_percent)}
            note="of moving time"
          />
          <.sensor_stat
            label="Pedal strokes"
            value={compact_number(@summary.revolutions)}
            note="crank revolutions recorded"
          />
        </dl>

        <section :if={@summary.cadence_count > 0} class="topo-card rounded-[1.7rem] p-5 sm:p-6">
          <h2 class="text-xl font-black">Cadence over time</h2>
          <p class="mt-2 text-xs text-[var(--ink-muted)]">
            Average pedaling cadence and coasting share for each ride. Terrain, traffic and group riding move both, so look for trends rather than single rides.
          </p>
          <div
            id="pedaling-history-chart"
            phx-hook="SensorSummaryChart"
            phx-update="ignore"
            data-kind="history"
            data-rows={json(@summary.history)}
            class="echarts-surface mt-4 h-80"
            role="img"
            aria-label="Average cadence and coasting percentage per ride over time"
          >
          </div>
        </section>

        <div :if={@summary.cadence_count > 0} class="grid grid-cols-1 gap-5 lg:grid-cols-2">
          <section class="topo-card min-w-0 rounded-[1.7rem] p-5 sm:p-6">
            <h2 class="text-lg font-black">Time by cadence, all rides</h2>
            <p class="mt-1 text-xs text-[var(--ink-muted)]">Moving time in 10 rpm bands.</p>
            <div
              id="pedaling-distribution"
              phx-hook="SensorSummaryChart"
              phx-update="ignore"
              data-kind="cadence_bands"
              data-rows={json(cadence_rows(@summary.cadence))}
              class="echarts-surface mt-3 h-64"
              role="img"
              aria-label="Moving time coasting and in each cadence band across all rides"
            >
            </div>
          </section>
          <section class="topo-card min-w-0 rounded-[1.7rem] p-5 sm:p-6">
            <h2 class="text-lg font-black">Your gearing, all rides</h2>
            <p class="mt-1 text-xs text-[var(--ink-muted)]">
              Distance per pedal stroke. Peaks are the gear combinations you use most.
            </p>
            <div
              id="pedaling-development"
              phx-hook="SensorSummaryChart"
              phx-update="ignore"
              data-kind="development"
              data-rows={json(@summary.development)}
              class="echarts-surface mt-3 h-64"
              role="img"
              aria-label="Pedaling time by metres per crank revolution across all rides"
            >
            </div>
          </section>
        </div>

        <section
          :if={@summary.cadence_count > 0}
          id="pedaling-terrain"
          class="topo-card rounded-[1.7rem] p-5 sm:p-6"
        >
          <h2 class="text-lg font-black">How terrain changes your pedaling</h2>
          <div class="mt-4 grid grid-cols-2 gap-3 md:grid-cols-4">
            <div
              :for={band <- @summary.terrain}
              id={"pedaling-terrain-#{band["band"]}"}
              class="rounded-2xl bg-[var(--surface-strong)] p-4"
            >
              <p class="text-xs font-bold text-[var(--ink-muted)]">{band["label"]}</p>
              <p class="metric-number mt-1 text-2xl font-black text-[var(--cadence)]">
                {rpm(band["average_rpm"])}
              </p>
              <p class="mt-1 text-xs text-[var(--ink-muted)]">
                {percent(band["coasting_percent"])} coasting · {duration(band["seconds"])}
              </p>
            </div>
          </div>
        </section>

        <section
          :if={@summary.calibration != []}
          id="pedaling-calibration"
          class="topo-card rounded-[1.7rem] p-5 sm:p-6"
        >
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="max-w-2xl">
              <h2 class="text-lg font-black">Speed sensor vs GPS distance</h2>
              <p class="mt-1 text-xs leading-5 text-[var(--ink-muted)]">
                A steady offset across rides usually means the wheel circumference set on the device is off. Single rides vary with GPS quality.
              </p>
            </div>
            <span class="rounded-full bg-[var(--surface-strong)] px-3 py-2 text-xs font-bold">
              Median {percent_change(@summary.median_difference_percent)}
            </span>
          </div>
          <div
            id="pedaling-calibration-chart"
            phx-hook="SensorSummaryChart"
            phx-update="ignore"
            data-kind="calibration"
            data-rows={json(@summary.calibration)}
            class="echarts-surface mt-4 h-56"
            role="img"
            aria-label="Device distance difference from GPS distance per ride"
          >
          </div>
        </section>

        <section :if={@summary.count > 0} class="topo-card rounded-[1.7rem] p-5 sm:p-6">
          <h2 class="text-xl font-black">Contributing rides</h2>
          <div id="pedaling-tracks" phx-update="stream" class="mt-4 divide-y divide-[var(--line)]">
            <.link
              :for={{id, row} <- @streams.sensor_tracks}
              id={id}
              navigate={~p"/tracks/#{row.track.id}"}
              class="grid gap-3 py-4 transition hover:text-[var(--cadence)] sm:grid-cols-[1fr_auto]"
            >
              <span class="min-w-0">
                <strong class="block truncate text-sm">{row.track.name}</strong>
                <span class="mt-1 block text-xs text-[var(--ink-muted)]">
                  {short_date(row.track.started_at)} · {String.upcase(row.track.source_format)}
                </span>
              </span>
              <span class="flex flex-wrap items-center gap-4 text-xs">
                <span :if={row.cadence["average_rpm"]}>
                  <strong>{rpm(row.cadence["average_rpm"])}</strong> avg
                </span>
                <span :if={row.cadence["coasting_percent"]}>
                  <strong>{percent(row.cadence["coasting_percent"])}</strong> coasting
                </span>
                <span :if={row.speed["distance_difference_percent"]}>
                  <strong>{percent_change(row.speed["distance_difference_percent"])}</strong> vs GPS
                </span>
                <.icon name="hero-arrow-up-right" class="size-4" />
              </span>
            </.link>
          </div>
        </section>
      </article>
    </Layouts.app>
    """
  end
end
