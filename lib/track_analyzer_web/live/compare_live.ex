defmodule TrackAnalyzerWeb.CompareLive do
  use TrackAnalyzerWeb, :live_view

  alias TrackAnalyzer.Tracks

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Tracks.subscribe()

    candidates = Tracks.list_tracks(%{"status" => "complete"})

    {:ok,
     socket
     |> assign(:page_title, "Compare tracks")
     |> assign(:selected_ids, [])
     |> assign(:comparison_json, "[]")
     |> stream(:candidates, candidates)
     |> stream(:selected, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    previous_ids = socket.assigns.selected_ids
    ids = parse_ids(params["ids"])
    selected = Tracks.compare_tracks(ids)

    changed_candidates =
      previous_ids
      |> symmetric_difference(ids)
      |> Tracks.compare_tracks()
      |> Enum.filter(&(&1.status == "complete"))

    payload =
      Enum.map(selected, fn track ->
        %{
          name: track.name,
          distance_km: divide(track.distance_m, 1_000),
          moving_hours: divide(track.moving_s, 3_600),
          avg_speed_kmh: multiply(track.avg_speed_mps, 3.6),
          elevation_gain_m: track.elevation_gain_m || 0,
          quality_score: track.quality_score || 0
        }
      end)

    socket =
      socket
      |> assign(:selected_ids, ids)
      |> assign(:comparison_json, json(payload))
      |> stream(:selected, selected, reset: true)

    {:noreply,
     Enum.reduce(changed_candidates, socket, fn track, socket ->
       stream_insert(socket, :candidates, track)
     end)}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id) do
      ids = socket.assigns.selected_ids

      cond do
        id in ids ->
          {:noreply, push_patch(socket, to: compare_path(List.delete(ids, id)))}

        length(ids) >= 4 ->
          {:noreply, put_flash(socket, :error, "Compare up to four tracks at once.")}

        true ->
          {:noreply, push_patch(socket, to: compare_path(ids ++ [id]))}
      end
    else
      _invalid -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:track_updated, _track}, socket) do
    candidates = Tracks.list_tracks(%{"status" => "complete"})
    {:noreply, stream(socket, :candidates, candidates, reset: true)}
  end

  defp parse_ids(nil), do: []

  defp parse_ids(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn part ->
      case Integer.parse(part) do
        {id, ""} when id > 0 -> [id]
        _invalid -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(4)
  end

  defp compare_path([]), do: ~p"/compare"
  defp compare_path(ids), do: ~p"/compare?#{[ids: Enum.join(ids, ",")]}"

  defp symmetric_difference(left, right), do: (left -- right) ++ (right -- left)

  defp divide(nil, _divisor), do: 0
  defp divide(number, divisor), do: number / divisor
  defp multiply(nil, _multiplier), do: 0
  defp multiply(number, multiplier), do: number * multiplier

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil} active="compare">
      <section id="compare-page">
        <header id="compare-header" class="max-w-4xl">
          <h1 class="text-3xl font-black tracking-[-0.045em] sm:text-4xl">Compare tracks</h1>
          <p class="mt-2 max-w-2xl text-sm leading-6 text-[var(--ink-muted)]">
            Select two to four tracks to compare distance, duration, speed, climbing, and data quality.
          </p>
        </header>

        <section class="mt-6 grid gap-5 xl:grid-cols-[0.65fr_1.35fr]">
          <aside class="topo-card rounded-[1.7rem] p-5">
            <div class="flex items-center justify-between">
              <div>
                <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                  Track picker
                </p><h2 class="mt-1 text-xl font-black">Choose 2–4</h2>
              </div><span class="metric-number rounded-full bg-[var(--accent)] px-3 py-1 text-sm font-black text-[var(--accent-ink)]">{length(
                @selected_ids
              )}/4</span>
            </div>
            <div
              id="compare-candidates"
              phx-update="stream"
              class="mt-5 max-h-[38rem] space-y-2 overflow-y-auto pr-1"
            >
              <div
                id="compare-candidates-empty"
                class="hidden only:block rounded-xl border border-dashed border-[var(--line)] p-6 text-center text-sm text-[var(--ink-muted)]"
              >
                Analyze tracks before comparing them.
              </div>
              <button
                :for={{id, track} <- @streams.candidates}
                id={id}
                type="button"
                phx-click="toggle"
                phx-value-id={track.id}
                aria-pressed={if(track.id in @selected_ids, do: "true", else: "false")}
                class={[
                  "grid w-full grid-cols-[auto_1fr_auto] items-center gap-3 rounded-xl border p-3 text-left transition",
                  track.id in @selected_ids &&
                    "border-[var(--accent-strong)] bg-[color-mix(in_srgb,var(--accent)_18%,transparent)]",
                  track.id not in @selected_ids &&
                    "border-[var(--line)] bg-[var(--surface-strong)] hover:border-[var(--ink-muted)]"
                ]}
              ><span class={[
                "grid size-5 place-items-center rounded-md border",
                track.id in @selected_ids &&
                  "border-[var(--accent-strong)] bg-[var(--accent)] text-[var(--accent-ink)]",
                track.id not in @selected_ids && "border-[var(--line)]"
              ]}><.icon :if={track.id in @selected_ids} name="hero-check" class="size-3.5" /></span><span class="min-w-0"><span class="block truncate text-sm font-bold">{track.name}</span><span class="mt-0.5 block text-xs text-[var(--ink-muted)]">{short_date(
                track.started_at
              )} · {duration(track.moving_s)}</span></span><span class="metric-number text-sm font-black">{distance(
                track.distance_m
              )}</span></button>
            </div>
          </aside>

          <div class="space-y-5">
            <div class="topo-card rounded-[1.7rem] p-5 sm:p-6">
              <div>
                <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                  Normalized comparison
                </p><h2 class="mt-1 text-xl font-black">Effort fingerprint</h2>
              </div>
              <div
                :if={length(@selected_ids) > 0}
                id="comparison-chart"
                phx-hook="CompareChart"
                phx-update="ignore"
                data-comparison={@comparison_json}
                class="echarts-surface mt-4 min-h-[25rem]"
              >
              </div>
              <div
                :if={length(@selected_ids) == 0}
                id="comparison-empty"
                class="contour-pattern grid min-h-[25rem] place-items-center rounded-2xl border border-dashed border-[var(--line)] text-center"
              >
                <div>
                  <span class="mx-auto grid size-14 place-items-center rounded-2xl bg-[var(--accent)]"><.icon
                    name="hero-arrows-right-left"
                    class="size-6"
                  /></span><h3 class="mt-4 text-lg font-black">Pick your first track</h3><p class="mt-2 text-sm text-[var(--ink-muted)]">
                    The comparison profile will build here.
                  </p>
                </div>
              </div>
            </div>

            <div id="selected-tracks" phx-update="stream" class="grid gap-4 md:grid-cols-2">
              <div
                :for={{id, track} <- @streams.selected}
                id={id}
                class="topo-card rounded-[1.5rem] p-5"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <p class="truncate text-lg font-black">{track.name}</p><p class="mt-1 text-xs text-[var(--ink-muted)]">
                      {short_date(track.started_at)}
                    </p>
                  </div><button
                    id={"remove-compare-#{track.id}"}
                    type="button"
                    phx-click="toggle"
                    phx-value-id={track.id}
                    class="grid size-9 shrink-0 place-items-center rounded-xl border border-[var(--line)] text-[var(--ink-muted)] hover:text-red-600"
                  ><.icon name="hero-x-mark" class="size-4" /></button>
                </div><div class="mt-5 grid grid-cols-2 gap-3">
                  <.compare_metric label="Distance" value={distance(track.distance_m)} /><.compare_metric
                    label="Average"
                    value={speed(track.avg_speed_mps)}
                  /><.compare_metric label="Moving" value={duration(track.moving_s)} /><.compare_metric
                    label="Ascent"
                    value={elevation(track.elevation_gain_m)}
                  />
                </div><.link
                  navigate={~p"/tracks/#{track.id}"}
                  class="mt-4 inline-flex items-center gap-1 text-xs font-bold text-[var(--ink-muted)] hover:text-[var(--ink)]"
                >Open analysis <.icon name="hero-arrow-up-right" class="size-3.5" /></.link>
              </div>
            </div>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp compare_metric(assigns) do
    ~H"""
    <div class="rounded-xl bg-[var(--canvas)] px-3 py-2.5">
      <p class="text-[10px] font-bold uppercase tracking-wider text-[var(--ink-muted)]">{@label}</p><p class="metric-number mt-1 text-lg font-black">
        {@value}
      </p>
    </div>
    """
  end
end
