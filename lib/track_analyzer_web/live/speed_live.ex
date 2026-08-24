defmodule TrackAnalyzerWeb.SpeedLive do
  use TrackAnalyzerWeb, :live_view

  alias TrackAnalyzer.Tracks

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Tracks.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Speed history")
     |> assign(:filters, %{"metric" => "100m", "range" => "all"})
     |> load_speed()}
  end

  @impl true
  def handle_event("filter", %{"speed" => filters}, socket) do
    {:noreply, socket |> assign(:filters, filters) |> load_speed()}
  end

  @impl true
  def handle_info({:track_updated, _track}, socket), do: {:noreply, load_speed(socket)}

  defp load_speed(socket) do
    history = Tracks.speed_history(socket.assigns.filters)

    chart = %{
      metric: history.metric,
      points:
        Enum.map(history.points, fn point ->
          point
          |> Map.update!(:started_at, &DateTime.to_iso8601/1)
          |> Map.update(:metric_mps, nil, &to_kmh/1)
          |> Map.update(:rolling_median_mps, nil, &to_kmh/1)
          |> Map.update(:record_mps, nil, &to_kmh/1)
        end)
    }

    socket
    |> assign(:form, to_form(socket.assigns.filters, as: :speed))
    |> assign(:history, history)
    |> assign(:chart_json, json(chart))
    |> assign(:history_empty?, history.points == [])
    |> stream(:leaders, history.leaders, reset: true)
  end

  defp to_kmh(nil), do: nil
  defp to_kmh(value), do: Float.round(value * 3.6, 2)

  defp record_note(nil), do: "Waiting for a qualified effort"
  defp record_note(record), do: "#{short_date(record.started_at)} · #{record.name}"

  defp trend(nil), do: "—"
  defp trend(value) when value > 0, do: "+#{percent(value)}"
  defp trend(value), do: percent(value)

  defp trend_note(nil), do: "needs 30 activities"
  defp trend_note(_value), do: "last 15 vs prior 15"

  defp metric_label("instantaneous"), do: "Instant peak"
  defp metric_label("500m"), do: "Best 500 m"
  defp metric_label(_metric), do: "Best 100 m"

  defp confidence_classes("high"), do: "bg-emerald-400/15 text-emerald-700 dark:text-emerald-300"
  defp confidence_classes("medium"), do: "bg-amber-400/15 text-amber-800 dark:text-amber-300"
  defp confidence_classes(_confidence), do: "bg-red-400/15 text-red-700 dark:text-red-300"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil} active="speed">
      <section id="speed-lab" class="space-y-5">
        <header
          id="speed-header"
          class="relative overflow-hidden rounded-[1.7rem] bg-[var(--ink)] px-5 py-5 text-[var(--canvas)] shadow-xl sm:px-7 sm:py-6"
        >
          <div class="contour-pattern absolute inset-0 opacity-35"></div>
          <div class="relative flex flex-wrap items-center justify-between gap-5">
            <div class="max-w-3xl">
              <h1 class="text-3xl font-black tracking-[-0.045em] sm:text-4xl">Speed history</h1>
              <p class="mt-2 max-w-2xl text-sm leading-6 text-white/58">
                Instantaneous peaks, sustained 100 m and 500 m efforts, rolling median, and record progression.
              </p>
            </div>
            <div class="rounded-2xl border border-white/12 bg-white/8 px-4 py-3 text-right">
              <p class="text-[10px] font-bold uppercase tracking-[0.16em] text-white/45">Analyzed</p>
              <p class="metric-number mt-1 text-2xl font-black">{length(@history.points)} tracks</p>
            </div>
          </div>
        </header>

        <section id="speed-records" class="grid grid-cols-2 gap-3 xl:grid-cols-4">
          <.record_card
            id="record-100m"
            label="100 m record"
            value={speed(@history.records.best_100m && @history.records.best_100m.speed_mps)}
            note={record_note(@history.records.best_100m)}
            icon="hero-rocket-launch"
            accent={true}
            record={@history.records.best_100m}
          />
          <.record_card
            id="record-instantaneous"
            label="Instant peak"
            value={speed(@history.records.instantaneous && @history.records.instantaneous.speed_mps)}
            note={record_note(@history.records.instantaneous)}
            icon="hero-bolt"
            record={@history.records.instantaneous}
          />
          <.record_card
            id="record-500m"
            label="500 m record"
            value={speed(@history.records.best_500m && @history.records.best_500m.speed_mps)}
            note={record_note(@history.records.best_500m)}
            icon="hero-forward"
            record={@history.records.best_500m}
          />
          <.record_card
            id="speed-trend"
            label="Recent median"
            value={trend(@history.recent_delta_percent)}
            note={trend_note(@history.recent_delta_percent)}
            icon="hero-chart-bar-square"
          />
        </section>

        <section class="topo-card overflow-hidden rounded-[1.7rem]">
          <div class="flex flex-wrap items-start justify-between gap-4 border-b border-[var(--line)] px-5 py-5 sm:px-6">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                Historical behavior
              </p>
              <h2 class="mt-1 text-2xl font-black tracking-[-0.04em]">
                {metric_label(@history.metric)} over time
              </h2>
              <p class="mt-1 text-sm text-[var(--ink-muted)]">
                Every track · rolling 15-track median · cumulative record
              </p>
            </div>
            <.form for={@form} id="speed-filters" phx-change="filter" class="grid grid-cols-2 gap-2">
              <.input
                field={@form[:metric]}
                type="select"
                label="Measure"
                options={[
                  {"100 m sustained", "100m"},
                  {"500 m sustained", "500m"},
                  {"Instant peak", "instantaneous"}
                ]}
              />
              <.input
                field={@form[:range]}
                type="select"
                label="Window"
                options={[{"All time", "all"}, {"Last 12 months", "12m"}, {"Last 90 days", "90d"}]}
              />
            </.form>
          </div>
          <div
            :if={!@history_empty?}
            id="speed-history-chart"
            phx-hook="SpeedHistoryChart"
            phx-update="ignore"
            data-history={@chart_json}
            class="echarts-surface min-h-[30rem] px-2 py-4 sm:px-5"
          >
          </div>
          <div
            :if={@history_empty?}
            id="speed-history-empty"
            class="contour-pattern grid min-h-[30rem] place-items-center px-6 text-center"
          >
            <div class="max-w-md">
              <span class="mx-auto grid size-14 place-items-center rounded-2xl bg-[var(--accent)]"><.icon
                name="hero-bolt"
                class="size-7"
              /></span>
              <h3 class="mt-4 text-xl font-black">No qualified speed efforts yet</h3>
              <p class="mt-2 text-sm leading-6 text-[var(--ink-muted)]">
                Import an OsmAnd export, then sustained efforts will build a trustworthy record history.
              </p>
            </div>
          </div>
        </section>

        <section class="topo-card rounded-[1.7rem] p-5 sm:p-6">
          <div class="flex flex-wrap items-end justify-between gap-3">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                Leaderboard
              </p>
              <h2 class="mt-1 text-xl font-black tracking-[-0.035em]">
                Fastest {metric_label(@history.metric) |> String.downcase()}
              </h2>
            </div>
            <p class="text-xs text-[var(--ink-muted)]">
              Raw GPS peaks carry a confidence flag; sustained efforts are naturally more robust.
            </p>
          </div>
          <div id="speed-leaders" phx-update="stream" class="mt-4 divide-y divide-[var(--line)]">
            <div
              id="speed-leaders-empty"
              class="hidden only:block py-10 text-center text-sm text-[var(--ink-muted)]"
            >
              No efforts in this window.
            </div>
            <.link
              :for={{id, track} <- @streams.leaders}
              id={id}
              navigate={~p"/tracks/#{track.id}"}
              class="group grid grid-cols-[2rem_1fr_auto] items-center gap-3 py-3.5"
            >
              <span class="metric-number text-sm font-black text-[var(--ink-muted)]">{leader_rank(
                @history.leaders,
                track
              )}</span>
              <div class="min-w-0">
                <p class="truncate text-sm font-bold group-hover:underline">{track.name}</p>
                <div class="mt-1 flex items-center gap-2 text-xs text-[var(--ink-muted)]">
                  <span>{short_date(track.started_at)}</span>
                  <span
                    :if={@history.metric == "instantaneous"}
                    class={[
                      "rounded-full px-1.5 py-0.5 text-[9px] font-bold uppercase",
                      confidence_classes(track.max_speed_confidence)
                    ]}
                  >
                    {track.max_speed_confidence || "low"} confidence
                  </span>
                </div>
              </div>
              <p class="metric-number text-lg font-black">{leader_speed(track, @history.metric)}</p>
            </.link>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp leader_rank(leaders, track) do
    leaders
    |> Enum.find_index(&(&1.id == track.id))
    |> then(&((&1 || 0) + 1))
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
  end

  defp leader_speed(track, "instantaneous"), do: speed(track.max_speed_mps)
  defp leader_speed(track, "500m"), do: speed(track.best_500m_speed_mps)
  defp leader_speed(track, _metric), do: speed(track.best_100m_speed_mps)

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, required: true
  attr :icon, :string, required: true
  attr :accent, :boolean, default: false
  attr :record, :map, default: nil

  defp record_card(assigns) do
    ~H"""
    <.link
      :if={@record}
      id={@id}
      navigate={~p"/tracks/#{@record.track_id}"}
      aria-label={"Open #{@label} source track #{@record.name}"}
      class={[
        "group rounded-[1.45rem] p-4 transition duration-200 hover:-translate-y-1 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--accent-strong)] sm:p-5",
        if(@accent, do: "bg-[var(--accent)] text-[var(--accent-ink)] shadow-lg", else: "topo-card")
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <p class={[
          "text-[10px] font-bold uppercase tracking-[0.14em]",
          if(@accent, do: "opacity-60", else: "text-[var(--ink-muted)]")
        ]}>
          {@label}
        </p>
        <span class={[
          "grid size-9 place-items-center rounded-xl transition",
          if(@accent,
            do: "bg-black/8",
            else:
              "bg-[color-mix(in_srgb,var(--accent)_25%,transparent)] group-hover:bg-[var(--accent)]"
          )
        ]}><.icon name={@icon} class="size-4" /></span>
      </div>
      <p class="metric-number mt-5 text-2xl font-black sm:text-3xl">{@value}</p>
      <div class="mt-1 flex items-center justify-between gap-2">
        <p class={[
          "min-w-0 truncate text-xs",
          if(@accent, do: "opacity-60", else: "text-[var(--ink-muted)]")
        ]}>
          {@note}
        </p>
        <.icon
          name="hero-arrow-up-right"
          class="size-4 shrink-0 transition group-hover:-translate-y-0.5 group-hover:translate-x-0.5"
        />
      </div>
    </.link>
    <article
      :if={!@record}
      id={@id}
      class={[
        "rounded-[1.45rem] p-4 sm:p-5",
        if(@accent, do: "bg-[var(--accent)] text-[var(--accent-ink)] shadow-lg", else: "topo-card")
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <p class={[
          "text-[10px] font-bold uppercase tracking-[0.14em]",
          if(@accent, do: "opacity-60", else: "text-[var(--ink-muted)]")
        ]}>
          {@label}
        </p>
        <span class={[
          "grid size-9 place-items-center rounded-xl transition",
          if(@accent,
            do: "bg-black/8",
            else: "bg-[color-mix(in_srgb,var(--accent)_25%,transparent)]"
          )
        ]}><.icon name={@icon} class="size-4" /></span>
      </div>
      <p class="metric-number mt-5 text-2xl font-black sm:text-3xl">{@value}</p>
      <p class={[
        "mt-1 truncate text-xs",
        if(@accent, do: "opacity-60", else: "text-[var(--ink-muted)]")
      ]}>
        {@note}
      </p>
    </article>
    """
  end
end
