defmodule TrackAnalyzerWeb.RouteProgressLive do
  use TrackAnalyzerWeb, :live_view

  alias TrackAnalyzer.Tracks.RouteProgress

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: RouteProgress.subscribe()

    {:ok,
     socket
     |> assign(:cluster_id, id)
     |> load_cluster()}
  end

  @impl true
  def handle_info({:route_progress_rebuilt, _result}, socket),
    do: {:noreply, load_cluster(socket)}

  defp load_cluster(socket) do
    cluster = RouteProgress.get_cluster!(socket.assigns.cluster_id)

    representative =
      Enum.find(cluster.attempts, &(&1.id == cluster.representative_track.id)) ||
        List.first(cluster.attempts)

    rendering =
      representative &&
        (Enum.find(representative.renderings, &(&1.level == "overview")) ||
           Enum.find(representative.renderings, &(&1.level == "detail")))

    history =
      Enum.map(cluster.attempts, fn track ->
        %{
          track_id: track.id,
          name: track.name,
          started_at: DateTime.to_iso8601(track.started_at),
          avg_speed_kmh: round_value(track.avg_speed_mps, 3.6),
          distance_km: round_value(track.distance_m, 0.001),
          quality_score: track.quality_score
        }
      end)

    fastest = Enum.max_by(cluster.attempts, &(&1.avg_speed_mps || 0.0), fn -> nil end)

    socket
    |> assign(:page_title, cluster.name)
    |> assign(:cluster, cluster)
    |> assign(:representative, representative)
    |> assign(:fastest, fastest)
    |> assign(:polyline, if(rendering, do: rendering.encoded_polyline, else: ""))
    |> assign(:history_json, json(history))
    |> assign(:sectors_json, json(cluster.sectors))
    |> stream(:attempts, Enum.reverse(cluster.attempts),
      reset: true,
      dom_id: fn track -> "route-attempt-#{track.id}" end
    )
  end

  defp round_value(nil, _factor), do: nil
  defp round_value(value, factor), do: Float.round(value * factor, 2)

  defp signed_percent(nil), do: "Building"
  defp signed_percent(value) when value > 0, do: "+#{percent(value)}"
  defp signed_percent(value), do: percent(value)

  defp direction_label("faster"), do: "Faster"
  defp direction_label("slower"), do: "Slower"
  defp direction_label("steady"), do: "Steady"
  defp direction_label(_direction), do: "Building"

  defp trend_classes("faster"), do: "text-emerald-700 dark:text-emerald-300"
  defp trend_classes("slower"), do: "text-orange-700 dark:text-orange-300"
  defp trend_classes("steady"), do: "text-cyan-800 dark:text-cyan-300"
  defp trend_classes(_direction), do: "text-[var(--ink-muted)]"

  defp sector_classes("faster"), do: "bg-emerald-400/15 text-emerald-700 dark:text-emerald-300"
  defp sector_classes("slower"), do: "bg-orange-400/15 text-orange-700 dark:text-orange-300"
  defp sector_classes(_direction), do: "bg-cyan-400/15 text-cyan-800 dark:text-cyan-300"

  defp similarity(cluster, track_id) do
    cluster.memberships
    |> Enum.find(&(&1.track_id == track_id))
    |> case do
      nil -> nil
      membership -> membership.similarity * 100
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil} active="progress">
      <article id="route-progress-detail" class="space-y-5">
        <header class="flex flex-wrap items-end justify-between gap-5">
          <div class="min-w-0">
            <.link
              navigate={~p"/progress"}
              class="inline-flex items-center gap-1 text-xs font-bold uppercase tracking-[0.16em] text-[var(--ink-muted)] hover:text-[var(--ink)]"
            >
              <.icon name="hero-arrow-left" class="size-4" /> Progress
            </.link>
            <div class="mt-4 flex flex-wrap items-center gap-3">
              <h1 class="break-words text-3xl font-black tracking-[-0.05em] sm:text-5xl">
                {@cluster.name}
              </h1>
              <span class={[
                "rounded-full bg-[var(--surface-strong)] px-2.5 py-1 text-[10px] font-black uppercase tracking-wider ring-1 ring-[var(--line)]",
                trend_classes(@cluster.trend.direction)
              ]}>
                {direction_label(@cluster.trend.direction)}
              </span>
            </div>
            <p class="mt-3 text-sm text-[var(--ink-muted)]">
              {@cluster.track_count} attempts · {short_date(@cluster.first_attempt_at)} to {short_date(
                @cluster.latest_attempt_at
              )}
              <span :if={@cluster.activity_type}> · {status_label(@cluster.activity_type)}</span>
            </p>
          </div>
          <.link
            :if={@representative}
            id="open-representative-track"
            navigate={~p"/tracks/#{@representative.id}"}
            class="inline-flex min-h-11 items-center gap-2 rounded-xl border border-[var(--line)] bg-[var(--surface-strong)] px-4 text-sm font-bold transition hover:-translate-y-0.5"
          >
            <.icon name="hero-map-pin" class="size-4" /> Representative track
          </.link>
        </header>

        <section id="route-progress-metrics" class="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <.metric
            label="Recorded change"
            value={signed_percent(@cluster.trend.delta_percent)}
            note={@cluster.trend.signal}
            accent={true}
          />
          <.metric
            label="Recent pace"
            value={speed(@cluster.trend.recent_speed_mps)}
            note={"baseline #{speed(@cluster.trend.baseline_speed_mps)}"}
          />
          <.metric
            label="Fastest attempt"
            value={speed(@fastest && @fastest.avg_speed_mps)}
            note={if(@fastest, do: short_date(@fastest.started_at), else: "—")}
          />
          <.metric
            label="Signal confidence"
            value={status_label(@cluster.confidence)}
            note={"±#{percent(@cluster.trend.noise_floor_percent)} normal variation"}
          />
        </section>

        <section class="grid gap-5 xl:grid-cols-[1.15fr_0.85fr]">
          <div class="topo-card overflow-hidden rounded-[1.7rem]">
            <div class="flex items-center justify-between gap-3 px-5 py-4">
              <div>
                <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                  Route reference
                </p>
                <h2 class="mt-1 text-xl font-black">Matched geometry</h2>
              </div>
              <p class="text-xs text-[var(--ink-muted)]">Hover or click a sector below</p>
            </div>
            <div
              id="route-progress-map"
              phx-hook="RouteProgressMap"
              phx-update="ignore"
              data-polyline={@polyline}
              data-sectors={@sectors_json}
              data-tile-url={Application.fetch_env!(:track_analyzer, :maps)[:tile_url]}
              data-attribution={Application.fetch_env!(:track_analyzer, :maps)[:attribution]}
              class="h-[30rem] border-t border-[var(--line)]"
            >
            </div>
          </div>

          <div class="topo-card overflow-hidden rounded-[1.7rem]">
            <div class="border-b border-[var(--line)] px-5 py-4">
              <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                Equal-distance split
              </p>
              <h2 class="mt-1 text-xl font-black">Latest vs prior attempts</h2>
              <p class="mt-1 text-xs text-[var(--ink-muted)]">
                Median of up to 5 earlier attempts · ±2% is steady
              </p>
            </div>
            <div
              :if={@cluster.sectors != []}
              id="route-sector-chart"
              phx-hook="RouteSectorChart"
              phx-update="ignore"
              data-sectors={@sectors_json}
              class="echarts-surface min-h-[22rem] p-3"
            >
            </div>
            <div
              :if={@cluster.sectors == []}
              id="route-sectors-empty"
              class="grid min-h-[22rem] place-items-center px-6 text-center text-sm text-[var(--ink-muted)]"
            >
              At least two complete attempts are needed for sector comparison.
            </div>
            <div
              :if={@cluster.sectors != []}
              class="grid grid-cols-5 gap-1 border-t border-[var(--line)] p-3"
            >
              <button
                :for={sector <- @cluster.sectors}
                id={"route-sector-#{sector.number}"}
                type="button"
                phx-click={JS.dispatch("route-sector:select", detail: %{sector: sector.number})}
                class={[
                  "rounded-lg px-1.5 py-2 text-center transition hover:-translate-y-0.5",
                  sector_classes(sector.direction)
                ]}
              >
                <span class="block text-[9px] font-bold uppercase">S{sector.number}</span>
                <span class="metric-number mt-0.5 block text-xs font-black">
                  {signed_percent(sector.delta_percent)}
                </span>
              </button>
            </div>
          </div>
        </section>

        <section class="topo-card overflow-hidden rounded-[1.7rem]">
          <div class="border-b border-[var(--line)] px-5 py-5 sm:px-6">
            <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
              Recorded history
            </p>
            <h2 class="mt-1 text-xl font-black">Average moving speed over time</h2>
            <p class="mt-1 text-sm text-[var(--ink-muted)]">
              Route-only attempts remove much of the distance and geometry mismatch in library-wide speed charts.
            </p>
          </div>
          <div
            id="route-trend-chart"
            phx-hook="RouteTrendChart"
            phx-update="ignore"
            data-history={@history_json}
            class="echarts-surface min-h-[25rem] p-3 sm:p-5"
          >
          </div>
        </section>

        <section class="topo-card rounded-[1.7rem] p-5 sm:p-6">
          <div>
            <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
              Source tracks
            </p>
            <h2 class="mt-1 text-xl font-black">Attempts</h2>
          </div>
          <div id="route-attempts" phx-update="stream" class="mt-4 divide-y divide-[var(--line)]">
            <.link
              :for={{id, track} <- @streams.attempts}
              id={id}
              navigate={~p"/tracks/#{track.id}"}
              class="group grid grid-cols-[1fr_auto] items-center gap-4 py-3.5 sm:grid-cols-[1fr_auto_auto_auto]"
            >
              <div class="min-w-0">
                <p class="truncate text-sm font-black group-hover:underline">{track.name}</p>
                <p class="mt-1 text-xs text-[var(--ink-muted)]">
                  {local_date(track.started_at, track.timezone)}
                </p>
              </div>
              <div class="hidden text-right sm:block">
                <p class="text-sm font-black">{distance(track.distance_m)}</p>
                <p class="text-[9px] uppercase tracking-wider text-[var(--ink-muted)]">distance</p>
              </div>
              <div class="hidden text-right sm:block">
                <p class="text-sm font-black">{percent(similarity(@cluster, track.id))}</p>
                <p class="text-[9px] uppercase tracking-wider text-[var(--ink-muted)]">route match</p>
              </div>
              <div class="text-right">
                <p class="metric-number text-base font-black">{speed(track.avg_speed_mps)}</p>
                <p class="text-[9px] uppercase tracking-wider text-[var(--ink-muted)]">moving avg</p>
              </div>
            </.link>
          </div>
        </section>

        <p class="px-2 text-xs leading-5 text-[var(--ink-muted)]">
          This is a route-relative performance signal, not a fitness assessment. Stops, traffic, weather, equipment, and recording quality remain possible explanations.
        </p>
      </article>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, required: true
  attr :accent, :boolean, default: false

  defp metric(assigns) do
    ~H"""
    <article class={[
      "rounded-2xl p-4 sm:p-5",
      if(@accent, do: "bg-[var(--accent)] text-[var(--accent-ink)] shadow-lg", else: "topo-card")
    ]}>
      <p class={[
        "text-[10px] font-bold uppercase tracking-[0.14em]",
        if(@accent, do: "opacity-60", else: "text-[var(--ink-muted)]")
      ]}>
        {@label}
      </p>
      <p class="metric-number mt-4 text-2xl font-black sm:text-3xl">{@value}</p>
      <p class={[
        "mt-1 text-xs leading-5",
        if(@accent, do: "opacity-60", else: "text-[var(--ink-muted)]")
      ]}>
        {@note}
      </p>
    </article>
    """
  end
end
