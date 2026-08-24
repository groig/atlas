defmodule TrackAnalyzerWeb.TrackIndexLive do
  use TrackAnalyzerWeb, :live_view

  alias TrackAnalyzer.Tracks

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Tracks.subscribe()

    filters = %{"q" => "", "status" => "all"}
    tracks = Tracks.list_tracks(filters)

    {:ok,
     socket
     |> assign(:page_title, "Tracks")
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> assign(:track_count, length(tracks))
     |> stream(:tracks, tracks)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    tracks = Tracks.list_tracks(filters)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> assign(:track_count, length(tracks))
     |> stream(:tracks, tracks, reset: true)}
  end

  @impl true
  def handle_info({:track_updated, _track}, socket) do
    tracks = Tracks.list_tracks(socket.assigns.filters)

    {:noreply,
     socket |> assign(:track_count, length(tracks)) |> stream(:tracks, tracks, reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil} active="tracks">
      <section id="tracks-page">
        <header id="tracks-header" class="max-w-3xl">
          <h1 class="text-3xl font-black tracking-[-0.045em] sm:text-4xl">Tracks</h1>
          <p class="mt-2 text-sm leading-6 text-[var(--ink-muted)]">
            Search, filter, and open analyzed tracks.
          </p>
        </header>

        <div class="topo-card mt-6 rounded-2xl p-4">
          <.form
            for={@filter_form}
            id="track-filter-form"
            phx-change="filter"
            class="grid gap-3 sm:grid-cols-[1fr_14rem_auto] sm:items-end"
          >
            <.input
              field={@filter_form[:q]}
              type="search"
              label="Search tracks"
              placeholder="Name or source file…"
              phx-debounce="250"
            />
            <.input
              field={@filter_form[:status]}
              type="select"
              label="Analysis state"
              options={[
                "All states": "all",
                Ready: "complete",
                Processing: "processing",
                "Needs data": "insufficient_data",
                Failed: "failed"
              ]}
            />
            <div class="mb-3 flex h-[42px] items-center rounded-xl border border-[var(--line)] bg-[var(--surface-strong)] px-4 text-sm">
              <strong class="metric-number mr-1">{@track_count}</strong><span class="text-[var(--ink-muted)]">tracks</span>
            </div>
          </.form>
        </div>

        <div
          id="track-library"
          phx-update="stream"
          class="mt-5 grid gap-4 md:grid-cols-2 xl:grid-cols-3"
        >
          <div
            id="track-library-empty"
            class="hidden only:grid min-h-64 place-items-center rounded-[1.7rem] border border-dashed border-[var(--line)] p-8 text-center md:col-span-2 xl:col-span-3"
          >
            <div>
              <span class="mx-auto grid size-14 place-items-center rounded-2xl bg-[var(--accent)]"><.icon
                name="hero-magnifying-glass"
                class="size-6"
              /></span><h2 class="mt-4 text-xl font-black">No tracks match</h2><p class="mt-2 text-sm text-[var(--ink-muted)]">
                Clear the search or adjust the analysis state filter.
              </p>
            </div>
          </div>
          <.link
            :for={{id, track} <- @streams.tracks}
            id={id}
            navigate={~p"/tracks/#{track.id}"}
            class="topo-card group relative overflow-hidden rounded-[1.7rem] p-5 transition duration-200 hover:-translate-y-1 hover:border-[var(--ink-muted)]"
          >
            <div class="absolute -right-8 -top-8 size-28 rounded-full bg-[color-mix(in_srgb,var(--accent)_18%,transparent)] blur-2xl transition group-hover:scale-150">
            </div>
            <div class="relative">
              <div class="flex items-start justify-between gap-4">
                <span class="grid size-11 shrink-0 place-items-center rounded-2xl bg-[var(--ink)] text-[var(--accent)]"><.icon
                  name="hero-map"
                  class="size-5"
                /></span><span class={[
                  "rounded-full px-2.5 py-1 text-[10px] font-bold uppercase tracking-wider ring-1",
                  status_classes(track.status)
                ]}>{status_label(track.status)}</span>
              </div>
              <h2 class="mt-5 truncate text-xl font-black tracking-[-0.035em] group-hover:underline">
                {track.name}
              </h2>
              <p class="mt-1 truncate text-xs text-[var(--ink-muted)]">
                {short_date(track.started_at)} · {track.source_filename}
              </p>
              <div class="mt-6 grid grid-cols-3 gap-3 border-t border-[var(--line)] pt-4">
                <.track_metric label="Distance" value={distance(track.distance_m)} /><.track_metric
                  label="Moving"
                  value={duration(track.moving_s)}
                /><.track_metric label="Climbing" value={elevation(track.elevation_gain_m)} />
              </div>
              <div :if={track.status not in ["complete", "insufficient_data", "failed"]} class="mt-4">
                <div class="mb-1.5 flex justify-between text-[10px] font-bold uppercase tracking-wider text-[var(--ink-muted)]">
                  <span>{track.stage}</span><span>{track.progress}%</span>
                </div><div class="h-1.5 overflow-hidden rounded-full bg-[var(--line)]">
                  <div
                    class="h-full rounded-full bg-[var(--accent-strong)] transition-all"
                    style={"width: #{track.progress}%"}
                  >
                  </div>
                </div>
              </div>
              <p
                :if={track.error}
                class="mt-4 line-clamp-2 rounded-xl bg-red-500/10 px-3 py-2 text-xs text-red-600"
              >
                {track.error}
              </p>
            </div>
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp track_metric(assigns) do
    ~H"""
    <div class="min-w-0">
      <p class="truncate text-[10px] font-bold uppercase tracking-wider text-[var(--ink-muted)]">
        {@label}
      </p><p class="metric-number mt-1 truncate text-sm font-black">{@value}</p>
    </div>
    """
  end
end
