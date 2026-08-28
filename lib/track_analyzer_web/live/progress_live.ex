defmodule TrackAnalyzerWeb.ProgressLive do
  use TrackAnalyzerWeb, :live_view

  alias TrackAnalyzer.Tracks
  alias TrackAnalyzer.Tracks.RouteProgress

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      RouteProgress.subscribe()
      RouteProgress.ensure_fresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Progress")
     |> assign(:filters, %{"activity" => "all", "trend" => "all", "attempts" => "2"})
     |> load_progress()}
  end

  @impl true
  def handle_event("filter", %{"progress" => filters}, socket) do
    {:noreply, socket |> assign(:filters, filters) |> load_progress()}
  end

  def handle_event("rebuild", _params, socket) do
    case RouteProgress.enqueue_rebuild(reason: "manual") do
      {:ok, _job} -> {:noreply, put_flash(socket, :info, "Route matching queued.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  def handle_event("upgrade_analysis", _params, socket) do
    {:ok, result} = Tracks.enqueue_stale_analyses()

    {:noreply,
     socket
     |> assign(:stale_analysis_count, 0)
     |> put_flash(:info, "Queued #{result.enqueued_count} outdated tracks for analysis.")}
  end

  @impl true
  def handle_info({:route_progress_rebuilt, _result}, socket),
    do: {:noreply, load_progress(socket)}

  defp load_progress(socket) do
    summary = RouteProgress.summary(socket.assigns.filters)

    socket
    |> assign(:summary, summary)
    |> assign(:stale_analysis_count, Tracks.stale_analysis_count())
    |> assign(
      :activity_options,
      [{"All", "all"} | Enum.map(summary.activities, &{activity_label(&1), &1})]
    )
    |> assign(:form, to_form(socket.assigns.filters, as: :progress))
    |> assign(:volume_json, json(summary.volume))
    |> assign(:clusters_empty?, summary.clusters == [])
    |> stream(:clusters, summary.clusters,
      reset: true,
      dom_id: fn cluster -> "matched-route-#{cluster.id}" end
    )
  end

  defp trend_value(%{direction: "building"}), do: "Building"

  defp trend_value(%{delta_percent: delta}) when is_number(delta) and delta > 0,
    do: "+#{percent(delta)}"

  defp trend_value(%{delta_percent: delta}), do: percent(delta)

  defp trend_note(%{signal: signal, noise_floor_percent: floor}),
    do: "#{signal} · ±#{percent(floor)} noise floor"

  defp trend_classes("faster"),
    do: "bg-emerald-400/15 text-emerald-700 dark:text-emerald-300"

  defp trend_classes("slower"), do: "bg-orange-400/15 text-orange-700 dark:text-orange-300"
  defp trend_classes("steady"), do: "bg-cyan-400/15 text-cyan-800 dark:text-cyan-300"
  defp trend_classes(_direction), do: "bg-[var(--surface-strong)] text-[var(--ink-muted)]"

  defp direction_label("faster"), do: "Faster"
  defp direction_label("slower"), do: "Slower"
  defp direction_label("steady"), do: "Steady"
  defp direction_label(_direction), do: "Building"

  defp effort_delta(nil), do: "Needs 10 efforts"
  defp effort_delta(delta) when delta > 0, do: "+#{percent(delta)}"
  defp effort_delta(delta), do: percent(delta)

  defp activity_label(activity), do: activity |> String.replace("_", " ") |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil} active="progress">
      <section id="progress-hub" class="space-y-5">
        <header class="relative overflow-hidden rounded-[1.7rem] bg-[var(--hero)] px-5 py-6 text-[var(--hero-ink)] shadow-xl sm:px-7">
          <div class="contour-pattern absolute inset-0 opacity-30"></div>
          <div class="relative flex flex-wrap items-end justify-between gap-5">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.17em] text-white/45">
                Repeatable routes
              </p>
              <h1 class="mt-1 text-3xl font-black tracking-[-0.045em] sm:text-4xl">Progress</h1>
              <p class="mt-2 max-w-2xl text-sm leading-6 text-white/58">
                Recorded performance on routes you repeat, separated from normal GPS and day-to-day variation.
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <.link
                id="speed-history-link"
                navigate={~p"/speed"}
                class="inline-flex min-h-11 items-center gap-2 rounded-xl border border-white/15 bg-white/8 px-4 text-sm font-bold transition hover:bg-white/13"
              >
                <.icon name="hero-bolt" class="size-4" /> Speed history
              </.link>
              <button
                :if={@stale_analysis_count > 0}
                id="upgrade-route-analysis"
                type="button"
                phx-click="upgrade_analysis"
                class="inline-flex min-h-11 items-center gap-2 rounded-xl border border-white/15 bg-white/8 px-4 text-sm font-bold transition hover:bg-white/13"
              >
                <.icon name="hero-arrow-up-circle" class="size-4" /> Upgrade {@stale_analysis_count}
              </button>
              <button
                id="rebuild-route-progress"
                type="button"
                phx-click="rebuild"
                class="inline-flex min-h-11 items-center gap-2 rounded-xl bg-[var(--accent)] px-4 text-sm font-black text-[var(--accent-ink)] transition hover:-translate-y-0.5"
              >
                <.icon name="hero-arrow-path" class="size-4" /> Rebuild matches
              </button>
            </div>
          </div>
        </header>

        <section
          :if={@summary.status.state in [:missing, :stale]}
          id="progress-building"
          class="topo-card flex items-start gap-4 rounded-[1.5rem] p-5"
        >
          <span class="grid size-11 shrink-0 place-items-center rounded-xl bg-[var(--accent)] text-[var(--accent-ink)]">
            <.icon name="hero-cpu-chip" class="size-5 motion-safe:animate-pulse" />
          </span>
          <div>
            <p class="font-black">Refreshing route matches</p>
            <p class="mt-1 text-sm leading-6 text-[var(--ink-muted)]">
              Your tracks remain available while the background matcher processes {@summary.status.eligible_count} eligible tracks.
            </p>
          </div>
        </section>

        <section id="progress-summary" class="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <.summary_card
            label="Matched routes"
            value={Integer.to_string(@summary.cluster_count)}
            note={"#{@summary.matched_track_count} attempts grouped"}
            icon="hero-map"
          />
          <.summary_card
            label="Faster signals"
            value={Integer.to_string(@summary.improving_count)}
            note="above each route’s noise floor"
            icon="hero-arrow-trending-up"
            accent={true}
          />
          <.summary_card
            label="Steady routes"
            value={Integer.to_string(@summary.steady_count)}
            note="change remains inside normal variation"
            icon="hero-minus"
          />
          <.summary_card
            label="Weekly streak"
            value={"#{@summary.streak_weeks} wk"}
            note="consecutive weeks with a track"
            icon="hero-fire"
          />
        </section>

        <section class="grid gap-5 xl:grid-cols-[1.35fr_0.65fr]">
          <div class="topo-card overflow-hidden rounded-[1.7rem]">
            <div class="flex flex-wrap items-start justify-between gap-4 border-b border-[var(--line)] px-5 py-5 sm:px-6">
              <div>
                <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                  Training volume
                </p>
                <h2 class="mt-1 text-xl font-black">Last 12 weeks</h2>
                <p class="mt-1 text-sm text-[var(--ink-muted)]">
                  Distance by week · last 4 vs prior 4: {effort_delta(@summary.volume.delta_percent)}
                </p>
              </div>
            </div>
            <div
              id="progress-volume-chart"
              phx-hook="ProgressVolumeChart"
              phx-update="ignore"
              data-volume={@volume_json}
              class="echarts-surface min-h-[20rem] p-4"
            >
            </div>
          </div>

          <div class="topo-card rounded-[1.7rem] p-5 sm:p-6">
            <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
              Sustained speed
            </p>
            <h2 class="mt-1 text-xl font-black">Effort pulse</h2>
            <div class="mt-5 space-y-3">
              <div
                :for={effort <- @summary.effort_trends}
                class="rounded-2xl border border-[var(--line)] bg-[var(--surface-strong)] p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <p class="text-xs font-bold uppercase tracking-[0.14em] text-[var(--ink-muted)]">
                      {effort.label}
                    </p>
                    <p class="metric-number mt-2 text-2xl font-black">
                      {speed(effort.recent_speed_mps)}
                    </p>
                  </div>
                  <span class="rounded-full bg-[color-mix(in_srgb,var(--accent)_24%,transparent)] px-2.5 py-1 text-xs font-black">
                    {effort_delta(effort.delta_percent)}
                  </span>
                </div>
                <p class="mt-2 text-xs text-[var(--ink-muted)]">recent 5 vs prior 5</p>
              </div>
            </div>
          </div>
        </section>

        <section class="topo-card rounded-[1.7rem] p-5 sm:p-6">
          <div class="flex flex-wrap items-end justify-between gap-4">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                Similar journeys
              </p>
              <h2 class="mt-1 text-2xl font-black tracking-[-0.04em]">Matched routes</h2>
            </div>
            <.form
              for={@form}
              id="progress-filters"
              phx-change="filter"
              class="grid grid-cols-3 gap-2"
            >
              <.input
                field={@form[:activity]}
                type="select"
                label="Activity"
                options={@activity_options}
              />
              <.input
                field={@form[:trend]}
                type="select"
                label="Signal"
                options={[
                  {"All", "all"},
                  {"Faster", "faster"},
                  {"Steady", "steady"},
                  {"Slower", "slower"},
                  {"Building", "building"}
                ]}
              />
              <.input
                field={@form[:attempts]}
                type="select"
                label="Attempts"
                options={[{"2+", "2"}, {"6+", "6"}, {"10+", "10"}]}
              />
            </.form>
          </div>

          <div
            id="matched-routes"
            phx-update="stream"
            class="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-3"
          >
            <div
              id="matched-routes-empty"
              class="col-span-full hidden rounded-2xl border border-dashed border-[var(--line)] px-6 py-14 text-center only:block"
            >
              <span class="mx-auto grid size-12 place-items-center rounded-xl bg-[var(--surface-strong)]">
                <.icon name="hero-map" class="size-6 text-[var(--ink-muted)]" />
              </span>
              <h3 class="mt-4 font-black">No matched routes in this view</h3>
              <p class="mt-1 text-sm text-[var(--ink-muted)]">
                Repeated tracks appear after route matching completes. Try broader filters if matches already exist.
              </p>
            </div>
            <.link
              :for={{id, cluster} <- @streams.clusters}
              id={id}
              navigate={~p"/progress/routes/#{cluster.id}"}
              class="group rounded-2xl border border-[var(--line)] bg-[var(--surface-strong)] p-4 transition duration-200 hover:-translate-y-1 hover:shadow-lg"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="truncate text-base font-black">{cluster.name}</p>
                  <p class="mt-1 text-xs text-[var(--ink-muted)]">
                    {cluster.track_count} attempts · {short_date(cluster.first_attempt_at)} → {short_date(
                      cluster.latest_attempt_at
                    )}
                  </p>
                </div>
                <span class={[
                  "shrink-0 rounded-full px-2.5 py-1 text-[10px] font-black uppercase tracking-wider",
                  trend_classes(cluster.trend.direction)
                ]}>
                  {direction_label(cluster.trend.direction)}
                </span>
              </div>
              <div class="mt-6 flex items-end justify-between gap-3">
                <div>
                  <p class="metric-number text-2xl font-black">{trend_value(cluster.trend)}</p>
                  <p class="mt-1 text-[11px] leading-4 text-[var(--ink-muted)]">
                    {trend_note(cluster.trend)}
                  </p>
                </div>
                <span class="grid size-10 shrink-0 place-items-center rounded-xl bg-[color-mix(in_srgb,var(--accent)_20%,transparent)] transition group-hover:bg-[var(--accent)] group-hover:text-[var(--accent-ink)]">
                  <.icon name="hero-arrow-up-right" class="size-4" />
                </span>
              </div>
            </.link>
          </div>
        </section>

        <p class="px-2 text-xs leading-5 text-[var(--ink-muted)]">
          Signals describe recorded speed on similar routes. Weather, traffic, stops, equipment, and GPS quality can all affect them; they are not a fitness diagnosis.
        </p>
      </section>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, required: true
  attr :icon, :string, required: true
  attr :accent, :boolean, default: false

  defp summary_card(assigns) do
    ~H"""
    <article class={[
      "rounded-[1.45rem] p-4 sm:p-5",
      if(@accent, do: "bg-[var(--accent)] text-[var(--accent-ink)] shadow-lg", else: "topo-card")
    ]}>
      <div class="flex items-start justify-between gap-3">
        <p class={[
          "text-[10px] font-bold uppercase tracking-[0.14em]",
          if(@accent, do: "opacity-60", else: "text-[var(--ink-muted)]")
        ]}>
          {@label}
        </p>
        <span class={[
          "grid size-9 place-items-center rounded-xl",
          if(@accent, do: "bg-black/8", else: "bg-[color-mix(in_srgb,var(--accent)_20%,transparent)]")
        ]}><.icon name={@icon} class="size-4" /></span>
      </div>
      <p class="metric-number mt-5 text-3xl font-black">{@value}</p>
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
