defmodule TrackAnalyzerWeb.HeartRateLive do
  use TrackAnalyzerWeb, :live_view
  import TrackAnalyzerWeb.HeartRateComponents
  alias TrackAnalyzer.Tracks
  alias TrackAnalyzer.Tracks.{HeartRates, HeartRateProgress, RouteProgress}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Tracks.subscribe()
      HeartRates.subscribe()
      RouteProgress.subscribe()
    end

    {:ok, socket |> assign(:page_title, "Heart rate · Progress") |> load() |> profile_form()}
  end

  @impl true
  def handle_event("profile_change", %{"profile" => params}, socket) do
    changeset = HeartRates.profile_changeset(params)

    {:noreply,
     socket
     |> assign(:profile_form, to_form(changeset, as: :profile))
     |> assign(:profile_mode, params["mode"])}
  end

  def handle_event("profile_save", %{"profile" => params}, socket) do
    case HeartRates.save_profile(params) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> load()
         |> profile_form()
         |> put_flash(
           :info,
           "Bands saved. Historical HR load is being recalculated in the background."
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, as: :profile))}
    end
  end

  def handle_event("upgrade_analysis", _, socket) do
    {:ok, result} = Tracks.enqueue_stale_analyses()

    {:noreply,
     socket
     |> load()
     |> put_flash(
       :info,
       "Queued #{result.enqueued_count} tracks. HR appears as analysis finishes."
     )}
  end

  @impl true
  def handle_info(:heart_rate_updated, socket), do: {:noreply, load(socket)}
  def handle_info({:track_updated, %{status: "complete"}}, socket), do: {:noreply, load(socket)}
  def handle_info({:track_updated, _track}, socket), do: {:noreply, socket}
  def handle_info({:route_progress_rebuilt, _result}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    summary = HeartRates.overview()
    routes = HeartRateProgress.routes()

    socket
    |> assign(:summary, Map.drop(summary, [:tracks]))
    |> assign(:weekly_json, json(summary.weeks))
    |> assign(:pending_count, HeartRates.pending_count())
    |> assign(:load_json, json(summary.load_history))
    |> assign(:stale_count, Tracks.stale_analysis_count())
    |> assign(:routes_empty?, routes == [])
    |> stream(:hr_tracks, Enum.map(summary.tracks, &Map.put(&1, :id, &1.track.id)), reset: true)
    |> stream(:hr_routes, routes, reset: true)
  end

  defp profile_form(socket) do
    profile = socket.assigns.summary.profile

    socket
    |> assign(:profile_form, to_form(HeartRates.profile_changeset(profile), as: :profile))
    |> assign(:profile_mode, profile["mode"] || "none")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil} active="progress">
      <article id="heart-rate-progress" class="space-y-5">
        <header class="relative overflow-hidden rounded-[1.7rem] bg-[var(--hero)] p-6 text-[var(--hero-ink)] sm:p-8">
          <div class="contour-pattern pointer-events-none absolute inset-0 opacity-20"></div>
          <div class="relative flex flex-wrap items-center justify-between gap-5">
            <div>
              <p class="flex items-center gap-2 text-xs font-bold uppercase tracking-[0.17em] text-[#fb7fa3]">
                <.icon name="hero-heart" class="size-4" />Progress
              </p><h1 class="mt-2 text-3xl font-black tracking-tight sm:text-4xl">
                Heart rate & effort
              </h1>
              <p class="mt-3 max-w-2xl text-sm leading-6 text-white/65">
                See the effort behind your speed, and how it changes on routes you repeat.
              </p>
            </div>
            <a
              href="#hr-settings"
              class="inline-flex min-h-11 items-center gap-2 rounded-xl border border-white/15 bg-white/8 px-4 text-sm font-bold"
            ><.icon name="hero-adjustments-horizontal" class="size-4" />Intensity bands</a>
          </div>
        </header>
        <.progress_tabs active="heart" />
        <div
          :if={@stale_count > 0}
          id="hr-upgrade-banner"
          class="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-[var(--line)] p-4 text-sm"
        >
          <p>{@stale_count} older analyses can be checked for HR in their original files.</p><.button
            id="hr-upgrade-analysis"
            phx-click="upgrade_analysis"
          >Update analyses</.button>
        </div>
        <div
          :if={@summary.count == 0}
          id="hr-empty"
          class="topo-card rounded-[1.7rem] p-8 text-center"
        >
          <.icon name="hero-heart" class="size-9 text-[var(--heart-rate)]" /><h2 class="mt-3 text-xl font-black">
            No HR recordings yet
          </h2>
          <p class="mx-auto mt-3 max-w-xl text-sm leading-6 text-[var(--ink-muted)]">
            Record a track with a heart-rate sensor connected to OsmAnd, then upload its OSF export. Existing tracks without HR keep their usual analysis. You do not need to configure zones to get started.
          </p>
          <.link
            navigate={~p"/import"}
            class="mt-5 inline-flex min-h-11 items-center gap-2 text-sm font-bold"
          >Import an export <.icon name="hero-arrow-right" class="size-4" /></.link>
        </div>
        <dl
          :if={@summary.count > 0}
          id="hr-history-summary"
          class="grid grid-cols-2 gap-3 lg:grid-cols-4"
        >
          <.hr_stat
            label="HR-recorded tracks"
            value={to_string(@summary.count)}
            note="all recorded history"
          />
          <.hr_stat label="Time with HR" value={duration(@summary.covered_s)} note="gaps excluded" />
          <.hr_stat
            label="7-day recorded load"
            value={compact_number(@summary.load_7)}
            note={
              if(@summary.profile["edges"],
                do: "weighted zone-minutes",
                else: "optional bands not configured"
              )
            }
          />
          <.hr_stat
            label="28-day recorded load"
            value={compact_number(@summary.load_28)}
            note="missing HR is not zero effort"
          />
        </dl>
        <section :if={@summary.count > 0} class="topo-card rounded-[1.7rem] p-5 sm:p-6">
          <h2 class="text-xl font-black">Recorded effort over time</h2><p class="mt-2 text-xs text-[var(--ink-muted)]">
            Up to two years of weekly time in absolute BPM bands. Blank weeks have no HR recordings, not necessarily no activity.
          </p>
          <div
            id="hr-weekly-chart"
            phx-hook="HeartRateSummaryChart"
            phx-update="ignore"
            data-kind="weekly"
            data-rows={@weekly_json}
            class="echarts-surface mt-4 h-80"
            role="img"
            aria-label="Weekly heart rate duration and intensity distribution"
          >
          </div>
        </section>
        <section
          :if={@summary.count > 0 && @summary.profile["edges"]}
          class="topo-card rounded-[1.7rem] p-5 sm:p-6"
        >
          <h2 class="text-xl font-black">Recorded load history</h2><p class="mt-2 text-xs text-[var(--ink-muted)]">
            Rolling 7- and 28-day totals over the last year, using your current bands. Gaps mean no HR data in that window.
          </p>
          <div
            id="hr-load-chart"
            phx-hook="HeartRateSummaryChart"
            phx-update="ignore"
            data-kind="load"
            data-rows={@load_json}
            class="echarts-surface mt-4 h-64"
            role="img"
            aria-label="Rolling seven and twenty-eight day HR recorded load"
          >
          </div>
        </section>
        <section :if={@summary.count > 0} id="hr-route-comparisons" class="space-y-4">
          <div>
            <h2 class="text-xl font-black">Same route, different effort?</h2><p class="mt-2 text-sm text-[var(--ink-muted)]">
              Matched sections separate changes in effort from changes in speed.
            </p>
          </div>
          <p
            :if={@routes_empty?}
            id="hr-routes-empty"
            class="topo-card rounded-2xl p-5 text-sm leading-6 text-[var(--ink-muted)]"
          >
            No repeated HR routes yet. Opposite directions and different activities are kept separate. Your track profiles and interval analysis are available immediately.
          </p>
          <div id="hr-routes" phx-update="stream" class="grid gap-3 md:grid-cols-2">
            <div :for={{id, route} <- @streams.hr_routes} id={id}>
              <.link
                navigate={~p"/progress/routes/#{route.id}"}
                class="topo-card group flex h-full items-start justify-between gap-4 rounded-2xl p-5 transition hover:border-[var(--heart-rate)]"
              >
                <span>
                  <strong class="text-sm">{route.name}</strong>
                  <span class="mt-2 block text-sm font-bold text-[var(--heart-rate)]">{cond do
                    route.signal.trend.available -> route.signal.trend.label
                    route.signal.pair.available -> route.signal.pair.label
                    true -> "Building a comparable history"
                  end}</span>
                  <span class="mt-2 block text-xs text-[var(--ink-muted)]">{route.signal.eligible_count} eligible / {route.signal.recorded_count} HR attempts · {if(
                    route.signal.trend.available,
                    do: "6-attempt trend",
                    else: "latest pair"
                  )}</span>
                </span>
                <.icon
                  name="hero-arrow-up-right"
                  class="size-4 shrink-0 transition group-hover:-translate-y-0.5"
                />
              </.link>
            </div>
          </div>
        </section>
        <section :if={@summary.count > 0} class="topo-card rounded-[1.7rem] p-5 sm:p-6">
          <h2 class="text-xl font-black">Contributing tracks</h2><p class="mt-1 text-xs text-[var(--ink-muted)]">
            Averages are time weighted. Open a track to inspect gaps and flagged readings.
          </p>
          <div id="hr-tracks" phx-update="stream" class="mt-4 divide-y divide-[var(--line)]">
            <.link
              :for={{id, row} <- @streams.hr_tracks}
              id={id}
              navigate={~p"/tracks/#{row.track.id}"}
              class="grid gap-3 py-4 transition hover:text-[var(--heart-rate)] sm:grid-cols-[1fr_auto]"
            >
              <span class="min-w-0"><strong class="block truncate text-sm">{row.track.name}</strong><span class="mt-1 block text-xs text-[var(--ink-muted)]">{short_date(
                row.track.started_at
              )} · {duration(row.hr["covered_s"])} with HR</span></span>
              <span class="flex flex-wrap items-center gap-4 text-xs"><span><strong>{bpm(
                row.hr["average_bpm"]
              )}</strong>
              avg</span><span><strong>{bpm(row.hr["maximum_bpm"])}</strong> peak</span><span>{percent(
                row.hr["coverage_percent"]
              )} coverage</span><.icon name="hero-arrow-up-right" class="size-4" /></span>
            </.link>
          </div>
        </section>
        <section id="hr-settings" class="topo-card scroll-mt-24 rounded-[1.7rem] p-5 sm:p-6">
          <h2 class="text-xl font-black">Optional intensity bands</h2>
          <p
            :if={@summary.count > 0}
            id="hr-calibration-state"
            role="status"
            data-state={if(@pending_count > 0, do: "pending", else: "ready")}
            class="mt-2 text-xs font-bold text-[var(--heart-rate)]"
          >
            {if(@pending_count > 0,
              do:
                "Updating saved history for #{@pending_count} tracks… Current bands are already used in this view.",
              else: "Recorded history is up to date."
            )}
          </p>
          <p class="mt-2 max-w-3xl text-sm leading-6 text-[var(--ink-muted)]">
            Use a maximum HR you already know, or your own band boundaries. We never infer maximum HR from age or from your highest recorded sample. These are descriptive training bands, not medical advice or measured physiological thresholds.
          </p>
          <.form
            for={@profile_form}
            id="hr-profile-form"
            phx-change="profile_change"
            phx-submit="profile_save"
            class="mt-5 space-y-4"
          >
            <.input
              field={@profile_form[:mode]}
              type="select"
              label="Band method"
              options={[
                {"Absolute BPM only (default)", "none"},
                {"Known maximum HR", "maximum"},
                {"Custom lower boundaries", "custom"}
              ]}
            />
            <div :if={@profile_mode == "maximum"} id="hr-maximum-fields">
              <.input
                field={@profile_form[:maximum]}
                type="number"
                label="Known maximum HR (BPM)"
                min="100"
                max="240"
                required
              />
              <p class="mt-2 text-xs text-[var(--ink-muted)]">
                Bands: below 60%, 60–70%, 70–80%, 80–90%, and 90%+ of your known maximum. Values above that maximum remain visible.
              </p>
            </div>
            <div
              :if={@profile_mode == "custom"}
              id="hr-custom-fields"
              class="grid grid-cols-2 gap-3 sm:grid-cols-5"
            >
              <.input
                :for={
                  {field, label} <- [
                    {:z1, "Z1 (30 BPM)"},
                    {:z2, "Z2 lower BPM"},
                    {:z3, "Z3 lower BPM"},
                    {:z4, "Z4 lower BPM"},
                    {:z5, "Z5 lower BPM"}
                  ]
                }
                field={@profile_form[field]}
                type="number"
                label={label}
                min="30"
                max="239"
                required
              />
            </div>
            <p class="max-w-3xl text-xs leading-5 text-[var(--ink-muted)]">
              Recorded load is minutes in each band × its number (1–5). It is not TSS, Relative Effort, a recovery recommendation, or a measure of all your training. Changing bands recalculates historical load in the background; tracks without HR remain unavailable.
            </p>
            <.button id="hr-profile-save" type="submit" phx-disable-with="Saving…">Save bands</.button>
          </.form>
        </section>
      </article>
    </Layouts.app>
    """
  end
end
