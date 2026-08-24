defmodule TrackAnalyzerWeb.ExploreLive do
  use TrackAnalyzerWeb, :live_view

  alias TrackAnalyzer.Tracks

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Tracks.subscribe()

    {:ok, socket |> assign(:page_title, "Explore") |> load_explore()}
  end

  @impl true
  def handle_info({:track_updated, _track}, socket), do: {:noreply, load_explore(socket)}

  defp load_explore(socket) do
    summary = Tracks.portfolio_summary()
    cells = Tracks.heatmap_cells(8_000)
    tracks = Tracks.list_tracks(%{"status" => "complete"})
    repeated = Enum.count(cells, &(&1.visits > 1))
    most_visited = Enum.max_by(cells, & &1.visits, fn -> nil end)

    leaders =
      tracks
      |> Enum.sort_by(&(&1.distance_m || 0), :desc)
      |> Enum.take(12)

    socket
    |> assign(:summary, summary)
    |> assign(:cells_json, json(cells))
    |> assign(:has_map?, cells != [])
    |> assign(:repeated_cells, repeated)
    |> assign(:most_visited, most_visited)
    |> stream(:leaders, leaders, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil} active="explore">
      <section id="explore-page">
        <header id="explore-header" class="grid items-center gap-5 lg:grid-cols-[1fr_auto]">
          <div>
            <h1 class="text-3xl font-black tracking-[-0.045em] sm:text-4xl">Route coverage</h1>
            <p class="mt-2 text-sm leading-6 text-[var(--ink-muted)]">
              Combined heatmap, repeated corridors, and coverage gaps.
            </p>
          </div>
          <div class="rounded-2xl border border-[var(--line)] bg-[var(--surface)] px-5 py-4">
            <p class="text-xs font-bold uppercase tracking-wider text-[var(--ink-muted)]">
              Coverage index
            </p><p class="metric-number mt-1 text-3xl font-black">
              {compact_number(@summary.unique_route_cells)}
            </p><p class="text-xs text-[var(--ink-muted)]">~150 m route cells</p>
          </div>
        </header>

        <section class="mt-6 grid gap-5 xl:grid-cols-[1.5fr_0.5fr]">
          <div class="topo-card overflow-hidden rounded-[1.8rem]">
            <div class="flex flex-wrap items-center justify-between gap-4 px-5 py-5 sm:px-6">
              <div>
                <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                  All-track heatmap
                </p><h2 class="mt-1 text-xl font-black">Combined route heatmap</h2>
              </div><div class="flex items-center gap-4 text-xs text-[var(--ink-muted)]">
                <span class="flex items-center gap-2"><i class="size-2 rounded-full bg-[#27d9c2]"></i>
                discovered</span><span class="flex items-center gap-2"><i class="size-2 rounded-full bg-[#ff6f3d]"></i>
                frequented</span>
              </div>
            </div>
            <div
              :if={@has_map?}
              id="explore-heatmap"
              phx-hook="HeatMap"
              phx-update="ignore"
              data-cells={@cells_json}
              data-tile-url={Application.fetch_env!(:track_analyzer, :maps)[:tile_url]}
              data-attribution={Application.fetch_env!(:track_analyzer, :maps)[:attribution]}
              class="h-[42rem] border-t border-[var(--line)]"
            >
            </div>
            <div
              :if={!@has_map?}
              id="explore-map-empty"
              class="contour-pattern grid h-[42rem] place-items-center border-t border-[var(--line)] px-6 text-center"
            >
              <div>
                <span class="mx-auto grid size-16 place-items-center rounded-2xl bg-[var(--accent)]"><.icon
                  name="hero-globe-alt"
                  class="size-8"
                /></span><h3 class="mt-5 text-xl font-black">No territory mapped yet</h3><p class="mt-2 text-sm text-[var(--ink-muted)]">
                  Import an OSF to reveal your route footprint.
                </p><.button navigate={~p"/import"} variant="primary" class="mt-5">Import export</.button>
              </div>
            </div>
          </div>

          <aside class="space-y-4">
            <.insight
              icon="hero-arrow-path-rounded-square"
              label="Repeated corridors"
              value={compact_number(@repeated_cells)}
              note="cells visited by multiple tracks"
            />
            <.insight
              icon="hero-fire"
              label="Most familiar zone"
              value={if(@most_visited, do: "#{@most_visited.visits}×", else: "—")}
              note="maximum track overlap"
            />
            <.insight
              icon="hero-map-pin"
              label="Mapped observations"
              value={compact_number(@summary.point_count)}
              note="valid and suspect GPS points retained"
            />
            <.insight
              icon="hero-check-badge"
              label="Portfolio confidence"
              value={percent(@summary.quality_score)}
              note="weighted track data quality"
            />
            <div class="rounded-[1.5rem] bg-[var(--ink)] p-5 text-[var(--canvas)] shadow-xl">
              <span class="grid size-10 place-items-center rounded-xl bg-[var(--accent)] text-[var(--accent-ink)]"><.icon
                name="hero-light-bulb"
                class="size-5"
              /></span><h3 class="mt-5 text-lg font-black">Coverage gaps</h3><p class="mt-2 text-sm leading-6 text-white/60">
                Cool-colored edges mark corridors visited less often and routes that do not yet connect.
              </p>
            </div>
          </aside>
        </section>

        <section class="topo-card mt-5 rounded-[1.8rem] p-5 sm:p-6">
          <div id="explore-leaderboard-header" class="mb-5">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                Distance leaderboard
              </p><h2 class="mt-1 text-2xl font-black tracking-[-0.035em]">Longest tracks</h2>
            </div>
          </div>
          <div
            id="explore-leaders"
            phx-update="stream"
            class="grid gap-3 md:grid-cols-2 xl:grid-cols-3"
          >
            <div
              id="explore-leaders-empty"
              class="hidden only:block rounded-2xl border border-dashed border-[var(--line)] p-8 text-center text-sm text-[var(--ink-muted)] md:col-span-2 xl:col-span-3"
            >
              Your longest tracks will surface here.
            </div>
            <.link
              :for={{id, track} <- @streams.leaders}
              id={id}
              navigate={~p"/tracks/#{track.id}"}
              class="group grid grid-cols-[auto_1fr_auto] items-center gap-3 rounded-2xl border border-[var(--line)] bg-[var(--surface-strong)] p-4 transition hover:-translate-y-0.5 hover:border-[var(--ink-muted)]"
            ><span class="grid size-9 place-items-center rounded-xl bg-[color-mix(in_srgb,var(--accent)_28%,transparent)] text-sm font-black">{track.id}</span><div class="min-w-0">
              <p class="truncate text-sm font-black group-hover:underline">{track.name}</p><p class="mt-1 text-xs text-[var(--ink-muted)]">
                {short_date(track.started_at)} · {elevation(track.elevation_gain_m)} up
              </p>
            </div><p class="metric-number font-black">{distance(track.distance_m)}</p></.link>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, required: true

  defp insight(assigns) do
    ~H"""
    <div class="topo-card rounded-[1.5rem] p-5">
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="text-xs font-bold uppercase tracking-[0.13em] text-[var(--ink-muted)]">
            {@label}
          </p><p class="metric-number mt-3 text-3xl font-black">{@value}</p>
        </div><span class="grid size-10 place-items-center rounded-xl bg-[color-mix(in_srgb,var(--accent)_25%,transparent)]"><.icon
          name={@icon}
          class="size-5"
        /></span>
      </div><p class="mt-2 text-xs text-[var(--ink-muted)]">{@note}</p>
    </div>
    """
  end
end
