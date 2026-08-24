defmodule TrackAnalyzerWeb.TrackShowLive do
  use TrackAnalyzerWeb, :live_view

  alias TrackAnalyzer.Tracks

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    track = Tracks.get_track!(id)
    if connected?(socket), do: Tracks.subscribe(track.id)

    {:ok,
     socket
     |> assign(:page_title, track.name)
     |> assign_track(track)
     |> stream(:events, track.events)
     |> stream(:splits, interesting_splits(track.splits))}
  end

  @impl true
  def handle_event("reanalyze", _params, socket) do
    case Tracks.reanalyze(socket.assigns.track) do
      {:ok, track} ->
        {:noreply, socket |> assign_track(track) |> put_flash(:info, "Fresh analysis queued.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  @impl true
  def handle_info({:track_updated, updated}, socket) do
    track = Tracks.get_track!(updated.id)

    {:noreply,
     socket
     |> assign_track(track)
     |> stream(:events, track.events, reset: true)
     |> stream(:splits, interesting_splits(track.splits), reset: true)}
  end

  defp assign_track(socket, track) do
    rendering =
      Enum.find(track.renderings, &(&1.level == "detail")) ||
        Enum.find(track.renderings, &(&1.level == "overview"))

    socket
    |> assign(:track, track)
    |> assign(:rendering, rendering)
    |> assign(:polyline, if(rendering, do: rendering.encoded_polyline, else: ""))
    |> assign(:series_json, json(if(rendering, do: rendering.series, else: %{})))
    |> assign(:complete?, track.status in ["complete", "insufficient_data"])
  end

  defp interesting_splits(splits) do
    efforts = splits |> Enum.filter(&(&1.kind == "best_effort")) |> Enum.sort_by(& &1.distance_m)

    fastest_kilometers =
      splits
      |> Enum.filter(&(&1.kind == "kilometer" and is_number(&1.duration_s)))
      |> Enum.sort_by(& &1.duration_s)
      |> Enum.take(5)

    efforts ++ fastest_kilometers
  end

  defp event_title(%{kind: "stop"}), do: "Stopped"
  defp event_title(%{kind: "climb"}), do: "Climb"
  defp event_title(event), do: status_label(event.kind)

  defp event_detail(%{kind: "stop"} = event), do: duration(event.duration_s)

  defp event_detail(%{kind: "climb", metrics: metrics}) do
    "#{elevation(metrics["gain_m"])} · #{percent(metrics["average_grade"])} avg"
  end

  defp event_detail(_event), do: "Detected event"

  defp split_title(%{kind: "best_effort", distance_m: distance}),
    do: "Best #{TrackAnalyzerWeb.FormatHelpers.distance(distance)}"

  defp split_title(%{kind: "kilometer", position: position}), do: "Fast km ##{position}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil} active="tracks">
      <article id="track-detail">
        <div class="flex flex-wrap items-start justify-between gap-5">
          <div class="min-w-0">
            <.link
              navigate={~p"/tracks"}
              class="inline-flex items-center gap-1 text-xs font-bold uppercase tracking-[0.16em] text-[var(--ink-muted)] hover:text-[var(--ink)]"
            ><.icon name="hero-arrow-left" class="size-4" /> Track library</.link><div class="mt-4 flex flex-wrap items-center gap-3">
              <h1 class="break-words text-3xl font-black tracking-[-0.05em] sm:text-5xl">
                {@track.name}
              </h1><span class={[
                "rounded-full px-2.5 py-1 text-[10px] font-bold uppercase tracking-wider ring-1",
                status_classes(@track.status)
              ]}>{status_label(@track.status)}</span>
            </div><p class="mt-3 text-sm text-[var(--ink-muted)]">
              {local_date(@track.started_at, @track.timezone)} · {@track.source_filename}<span :if={
                @track.timezone
              }> · {@track.timezone}</span>
            </p>
          </div>
          <div id="track-actions" class="flex gap-2">
            <.button navigate={~p"/compare?ids=#{@track.id}"}><.icon
              name="hero-arrows-right-left"
              class="size-4"
            /> Compare</.button><.button id="reanalyze-track" phx-click="reanalyze"><.icon
              name="hero-arrow-path"
              class="size-4"
            /> Reanalyze</.button>
          </div>
        </div>

        <section
          :if={!@complete?}
          id="track-processing"
          class="topo-card mt-8 overflow-hidden rounded-[1.7rem] p-6 sm:p-8"
        >
          <div class="flex items-start gap-4">
            <span class="grid size-12 shrink-0 place-items-center rounded-2xl bg-[var(--accent)]"><.icon
              name="hero-cpu-chip"
              class="size-6 motion-safe:animate-pulse"
            /></span><div class="min-w-0 flex-1">
              <div class="flex justify-between gap-4">
                <div>
                  <h2 class="text-xl font-black">{@track.stage}</h2><p class="mt-1 text-sm text-[var(--ink-muted)]">
                    Analysis runs in the background and survives navigation or reconnects.
                  </p>
                </div><span class="metric-number text-2xl font-black">{@track.progress}%</span>
              </div><div class="mt-5 h-2.5 overflow-hidden rounded-full bg-[var(--line)]">
                <div
                  class="h-full rounded-full bg-[var(--accent-strong)] transition-all duration-500"
                  style={"width: #{@track.progress}%"}
                >
                </div>
              </div><p
                :if={@track.error}
                class="mt-4 rounded-xl bg-red-500/10 px-3 py-2 text-sm text-red-600"
              >
                {@track.error}
              </p>
            </div>
          </div>
        </section>

        <section id="track-metrics" class="mt-7 grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
          <.metric label="Distance" value={distance(@track.distance_m)} note="spike filtered" />
          <.metric
            label="Moving"
            value={duration(@track.moving_s)}
            note={"#{duration(@track.elapsed_s)} elapsed"}
          />
          <.metric
            label="Avg speed"
            value={speed(@track.avg_speed_mps)}
            note="while moving"
          />
          <.metric
            label="Instant max"
            value={speed(@track.max_speed_mps)}
            note={confidence_note(@track.max_speed_confidence)}
          />
          <.metric
            label="Best 100 m"
            value={speed(@track.best_100m_speed_mps)}
            note="sustained"
          />
          <.metric
            label="Best 500 m"
            value={speed(@track.best_500m_speed_mps)}
            note="sustained"
          />
        </section>

        <section class="mt-5 grid gap-5 xl:grid-cols-[1.35fr_0.65fr]">
          <div class="topo-card overflow-hidden rounded-[1.7rem]">
            <div class="flex items-center justify-between px-5 py-4">
              <div>
                <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                  Spatial trace
                </p><h2 class="mt-1 text-xl font-black">Route map</h2>
              </div><span id="track-map-instructions" class="text-xs text-[var(--ink-muted)]">
                Hover to preview · click or tap to pin
              </span>
            </div>
            <div
              :if={@rendering}
              id="track-map"
              phx-hook="TrackMap"
              phx-update="ignore"
              data-polyline={@polyline}
              data-tile-url={Application.fetch_env!(:track_analyzer, :maps)[:tile_url]}
              data-attribution={Application.fetch_env!(:track_analyzer, :maps)[:attribution]}
              class="h-[32rem] border-t border-[var(--line)]"
            >
            </div>
            <div
              :if={!@rendering}
              id="track-map-empty"
              class="contour-pattern grid h-[32rem] place-items-center border-t border-[var(--line)] text-sm text-[var(--ink-muted)]"
            >
              A map will appear when indexing completes.
            </div>
          </div>

          <aside class="topo-card rounded-[1.7rem] p-5">
            <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
              Signal audit
            </p><h2 class="mt-1 text-xl font-black">Data confidence</h2>
            <div class="mt-5 space-y-4">
              <.quality_row
                label="GPS spikes rejected"
                value={@track.quality["invalid_spike_points"] || 0}
              /><.quality_row
                label="Coordinates rejected"
                value={@track.quality["invalid_coordinate_points"] || 0}
              /><.quality_row
                label="Missing timestamps"
                value={@track.quality["missing_time_points"] || 0}
              /><.quality_row
                label="High dilution (HDOP)"
                value={@track.quality["high_hdop_points"] || 0}
              />
            </div>
            <div class="mt-6 rounded-2xl border border-[var(--line)] bg-[var(--surface-strong)] p-4">
              <div class="flex items-center justify-between gap-3">
                <p class="text-xs font-bold uppercase tracking-wider text-[var(--ink-muted)]">
                  Peak speed confidence
                </p>
                <span class="rounded-full bg-[color-mix(in_srgb,var(--accent)_25%,transparent)] px-2 py-1 text-[10px] font-black uppercase">
                  {@track.max_speed_confidence || "not rated"}
                </span>
              </div>
              <p class="mt-2 text-sm leading-6 text-[var(--ink-muted)]">
                {speed_confidence_detail(@track)}
              </p>
            </div>
            <div class="mt-6 rounded-2xl bg-[color-mix(in_srgb,var(--accent)_20%,transparent)] p-4">
              <p class="text-xs font-bold uppercase tracking-wider text-[var(--ink-muted)]">
                Track character
              </p><p class="mt-2 text-sm font-semibold leading-6">
                Displacement {distance(@track.stats["displacement_m"])} · sinuosity {if @track.stats[
                                                                                          "sinuosity"
                                                                                        ],
                                                                                        do:
                                                                                          :erlang.float_to_binary(
                                                                                            @track.stats[
                                                                                              "sinuosity"
                                                                                            ],
                                                                                            decimals:
                                                                                              2
                                                                                          ),
                                                                                        else: "—"} · sample every {duration(
                  @track.stats["median_sample_seconds"]
                )}
              </p>
            </div>
          </aside>
        </section>

        <section :if={@rendering} class="topo-card mt-5 rounded-[1.7rem] p-4 sm:p-6">
          <div>
            <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
              Terrain × tempo
            </p><h2 class="mt-1 text-xl font-black">Elevation and speed profile</h2>
          </div>
          <div
            id="track-profile-chart"
            phx-hook="TrackChart"
            phx-update="ignore"
            data-series={@series_json}
            class="echarts-surface mt-4 min-h-[24rem]"
          >
          </div>
        </section>

        <section class="mt-5 grid gap-5 lg:grid-cols-2">
          <div class="topo-card rounded-[1.7rem] p-5 sm:p-6">
            <div class="mb-4">
              <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                Notable moments
              </p><h2 class="mt-1 text-xl font-black">Stops and climbs</h2>
            </div><div id="track-events" phx-update="stream" class="space-y-2">
              <div
                id="track-events-empty"
                class="hidden only:block rounded-xl border border-dashed border-[var(--line)] p-6 text-center text-sm text-[var(--ink-muted)]"
              >
                No notable stops or sustained climbs detected.
              </div><div
                :for={{id, event} <- @streams.events}
                id={id}
                class="flex items-center gap-3 rounded-xl border border-[var(--line)] bg-[var(--surface-strong)] px-4 py-3"
              >
                <span class="grid size-9 place-items-center rounded-xl bg-[color-mix(in_srgb,var(--accent)_25%,transparent)]"><.icon
                  name={if(event.kind == "climb", do: "hero-arrow-trending-up", else: "hero-pause")}
                  class="size-4"
                /></span><div class="min-w-0 flex-1">
                  <p class="text-sm font-bold">{event_title(event)}</p><p class="text-xs text-[var(--ink-muted)]">
                    at {distance(event.start_distance_m)}
                  </p>
                </div><p class="text-sm font-black">{event_detail(event)}</p>
              </div>
            </div>
          </div>
          <div class="topo-card rounded-[1.7rem] p-5 sm:p-6">
            <div class="mb-4">
              <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                Personal pace
              </p><h2 class="mt-1 text-xl font-black">Best efforts and splits</h2>
            </div><div id="track-splits" phx-update="stream" class="space-y-2">
              <div
                id="track-splits-empty"
                class="hidden only:block rounded-xl border border-dashed border-[var(--line)] p-6 text-center text-sm text-[var(--ink-muted)]"
              >
                Longer tracks reveal best efforts here.
              </div><div
                :for={{id, split} <- @streams.splits}
                id={id}
                class="grid grid-cols-[1fr_auto_auto] items-center gap-4 rounded-xl border border-[var(--line)] bg-[var(--surface-strong)] px-4 py-3"
              >
                <div>
                  <p class="text-sm font-bold">{split_title(split)}</p><p class="text-xs text-[var(--ink-muted)]">
                    {distance(split.start_distance_m)} → {distance(split.end_distance_m)}
                  </p>
                </div><div class="text-right">
                  <p class="text-sm font-black">{duration(split.duration_s)}</p><p class="text-[10px] uppercase text-[var(--ink-muted)]">
                    time
                  </p>
                </div><div class="text-right">
                  <p class="text-sm font-black">{speed(split.avg_speed_mps)}</p><p class="text-[10px] uppercase text-[var(--ink-muted)]">
                    average
                  </p>
                </div>
              </div>
            </div>
          </div>
        </section>
      </article>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, required: true

  defp metric(assigns) do
    ~H"""
    <div class="topo-card rounded-2xl p-4">
      <p class="text-[10px] font-bold uppercase tracking-[0.14em] text-[var(--ink-muted)]">
        {@label}
      </p><p class="metric-number mt-3 text-2xl font-black">{@value}</p><p class="mt-1 truncate text-xs text-[var(--ink-muted)]">
        {@note}
      </p>
    </div>
    """
  end

  defp confidence_note(nil), do: "not rated"
  defp confidence_note(confidence), do: "#{confidence} confidence"

  defp speed_confidence_detail(track) do
    case track.stats["max_speed_confidence_reasons"] do
      reasons when is_list(reasons) and reasons != [] ->
        Enum.join(reasons, " · ")

      _reasons ->
        "Timing, GPS precision, and adjacent samples are checked before a peak is trusted."
    end
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp quality_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between border-b border-[var(--line)] pb-3 last:border-0">
      <span class="text-sm text-[var(--ink-muted)]">{@label}</span><span class="metric-number rounded-lg bg-[var(--surface-strong)] px-2 py-1 text-sm font-black">{@value}</span>
    </div>
    """
  end
end
