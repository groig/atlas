defmodule TrackAnalyzerWeb.HeartRateComponents do
  use TrackAnalyzerWeb, :html
  alias TrackAnalyzer.Tracks.HeartRate

  attr :active, :string, required: true

  def progress_tabs(assigns) do
    ~H"""
    <nav
      id="progress-tabs"
      aria-label="Progress views"
      class="flex w-fit max-w-full gap-1 overflow-x-auto rounded-2xl border border-[var(--line)] bg-[var(--surface)] p-1"
    >
      <.link
        :for={
          {label, href, key, icon} <- [
            {"Routes & speed", ~p"/progress", "routes", "hero-arrow-trending-up"},
            {"Heart rate", ~p"/progress/heart-rate", "heart", "hero-heart"},
            {"Pedaling", ~p"/progress/pedaling", "pedaling", "hero-arrow-path"}
          ]
        }
        id={"progress-tab-#{key}"}
        navigate={href}
        aria-current={if(@active == key, do: "page")}
        class={[
          "inline-flex min-h-11 shrink-0 items-center gap-2 rounded-xl px-4 text-sm font-bold transition",
          if(@active == key,
            do: "bg-[var(--ink)] text-[var(--canvas)]",
            else: "text-[var(--ink-muted)] hover:bg-[var(--surface-strong)]"
          )
        ]}
      >
        <.icon name={icon} class="size-4" />{label}
      </.link>
    </nav>
    """
  end

  defp cadence_lock_detail(lock) do
    ranges =
      Enum.map_join(lock["segments"] || [], ", ", fn segment ->
        "km #{km(segment["start_distance_m"])}–#{km(segment["end_distance_m"])} " <>
          "(≈#{round(segment["average_bpm"] || 0)} bpm vs #{round(segment["average_rpm"] || 0)} rpm)"
      end)

    "The wrist sensor reported pedaling cadence as heart rate at #{ranges}. " <>
      "Those readings are kept, but left out of averages, maximum and zones."
  end

  defp km(nil), do: "?"
  defp km(meters), do: :erlang.float_to_binary(meters / 1_000, decimals: 1)

  attr :hr, :map, required: true
  attr :quality, :map, required: true
  attr :series, :string, required: true
  attr :origin, :any, required: true
  attr :range_form, :any, required: true
  attr :selection, :any, default: nil

  def track_heart_rate(assigns) do
    ~H"""
    <section id="track-heart-rate" class="mt-5 space-y-5">
      <div class="topo-card overflow-hidden rounded-[1.7rem] p-5 sm:p-6">
        <header class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <p class="flex items-center gap-2 text-xs font-bold uppercase tracking-[0.15em] text-[var(--heart-rate)]">
              <.icon name="hero-heart" class="size-4" />Recorded effort
            </p>
            <h2 class="mt-1 text-2xl font-black">Heart rate</h2>
            <p class="mt-2 text-sm text-[var(--ink-muted)]">
              {duration(@hr["covered_s"])} recorded · {percent(@hr["coverage_percent"])} time coverage
            </p>
            <p
              :if={(get_in(@hr, ["cadence_lock", "samples"]) || 0) > 0}
              id="track-hr-cadence-lock"
              title={cadence_lock_detail(@hr["cadence_lock"])}
              class="mt-2 inline-flex items-center gap-1.5 rounded-full border border-[var(--line)] px-2.5 py-1 text-[11px] font-semibold text-[var(--ink-muted)]"
            >
              <.icon name="hero-arrow-path" class="size-3.5" />
              Cadence lock · {duration(@hr["cadence_lock"]["seconds"])} excluded
            </p>
          </div>
          <.link
            id="track-hr-progress"
            navigate={~p"/progress/heart-rate"}
            class="inline-flex min-h-11 items-center gap-2 text-sm font-bold"
          >HR progress <.icon name="hero-arrow-up-right" class="size-4" /></.link>
        </header>
        <dl class="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
          <.hr_stat label="Average" value={bpm(@hr["average_bpm"])} note="time weighted" />
          <.hr_stat
            label="Moving average"
            value={bpm(@hr["moving_average_bpm"])}
            note="valid moving intervals"
          />
          <.hr_stat
            label="Recorded range"
            value={"#{bpm(@hr["minimum_bpm"])} – #{bpm(@hr["maximum_bpm"])}"}
          />
          <.hr_stat
            label="Highest 1-minute average"
            value={bpm(get_in(@hr, ["duration_curve", Access.at(0), "average_bpm"]))}
            note="sustained observation"
          />
        </dl>
        <div class="mt-6 flex flex-wrap items-center justify-between gap-3">
          <div
            id="hr-axis-controls"
            class="flex gap-1 rounded-xl border border-[var(--line)] p-1"
            aria-label="Chart horizontal axis"
          >
            <button
              :for={{label, axis} <- [{"Time", "time"}, {"Distance", "distance"}]}
              id={"hr-axis-#{axis}"}
              type="button"
              aria-pressed={to_string(axis == "time")}
              phx-click={JS.dispatch("hr:axis", detail: %{axis: axis})}
              class="min-h-10 rounded-lg px-3 text-xs font-bold aria-pressed:bg-[var(--ink)] aria-pressed:text-[var(--canvas)]"
            >{label}</button>
          </div>
          <button
            id="hr-brush-toggle"
            type="button"
            aria-pressed="false"
            phx-click={JS.dispatch("hr:brush")}
            class="inline-flex min-h-11 items-center gap-2 rounded-xl border border-[var(--line)] px-4 text-xs font-bold aria-pressed:bg-[var(--heart-rate)] aria-pressed:text-white"
          >
            <.icon name="hero-cursor-arrow-rays" class="size-4" /> Drag to select
          </button>
        </div>
        <div
          id="heart-rate-chart"
          phx-hook="HeartRateChart"
          phx-update="ignore"
          data-series={@series}
          data-origin={@origin && DateTime.to_iso8601(@origin)}
          data-selection={json(@selection)}
          class="echarts-surface mt-3 h-[30rem]"
          role="img"
          aria-label="Heart rate, speed and elevation profiles. Hover or tap to trace the route; use the interval form below for keyboard selection."
        >
        </div>
        <p class="text-xs leading-5 text-[var(--ink-muted)]">
          Hover to trace · tap to pin · gaps stay visible. Shaded intervals and flagged transitions are observations, not performance awards.
        </p>
        <.form
          for={@range_form}
          id="hr-range-form"
          phx-submit="hr_range"
          class="mt-5 grid grid-cols-2 items-end gap-3 sm:grid-cols-[1fr_1fr_auto_auto]"
        >
          <.input
            field={@range_form[:from]}
            type="number"
            label="Start (minutes)"
            min="0"
            step="0.1"
            required
          />
          <.input
            field={@range_form[:until]}
            type="number"
            label="End (minutes)"
            min="0"
            step="0.1"
            required
          />
          <.button id="hr-range-submit" type="submit">Inspect interval</.button>
          <.button id="hr-range-clear" type="button" phx-click="hr_clear">Clear</.button>
        </.form>
        <div
          :if={@selection}
          id="hr-selection"
          class="mt-4 rounded-2xl border border-[color-mix(in_srgb,var(--heart-rate)_40%,transparent)] bg-[color-mix(in_srgb,var(--heart-rate)_7%,transparent)] p-4"
          aria-live="polite"
        >
          <h3 class="text-sm font-bold">
            Selected {elapsed_time(@selection["start_s"])}–{elapsed_time(@selection["end_s"])}
          </h3>
          <dl class="mt-3 grid grid-cols-2 gap-4 sm:grid-cols-4">
            <.hr_stat
              label="Duration · distance"
              value={"#{duration(@selection["duration_s"])} · #{distance(@selection["distance_m"])}"}
            />
            <.hr_stat
              label="Moving speed"
              value={if(@selection["speed_kmh"], do: speed(@selection["speed_kmh"] / 3.6), else: "—")}
            />
            <.hr_stat
              label="Average · peak"
              value={"#{bpm(@selection["average_bpm"])} · #{bpm(@selection["maximum_bpm"])}"}
            />
            <.hr_stat
              label="HR change"
              value={signed_bpm(@selection["change_bpm"])}
              note={"#{duration(@selection["covered_s"])} with HR"}
            />
          </dl>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-5 lg:grid-cols-2">
        <div class="topo-card min-w-0 rounded-[1.7rem] p-5 sm:p-6">
          <h3 class="text-lg font-black">Time by heart rate</h3><p class="mt-1 text-xs text-[var(--ink-muted)]">
            Absolute 10 BPM bands, not personalized zones.
          </p>
          <div
            id="hr-distribution"
            phx-hook="HeartRateSummaryChart"
            phx-update="ignore"
            data-kind="distribution"
            data-rows={json(HeartRate.distribution(@hr))}
            class="echarts-surface mt-3 h-56"
            role="img"
            aria-label="Time in ten BPM bands"
          >
          </div>
          <h4 class="mt-3 text-xs font-bold text-[var(--ink-muted)]">Time at or above BPM</h4>
          <div
            id="hr-time-above"
            phx-hook="HeartRateSummaryChart"
            phx-update="ignore"
            data-kind="cumulative"
            data-rows={json(@hr["histogram"] || [])}
            class="echarts-surface h-48"
            role="img"
            aria-label="Cumulative time at or above each heart rate"
          >
          </div>
        </div>
        <div class="topo-card rounded-[1.7rem] p-5 sm:p-6">
          <h3 class="text-lg font-black">Sustained HR</h3><p class="mt-1 text-xs leading-5 text-[var(--ink-muted)]">
            Highest continuous averages. Select one to inspect its track section; higher is not better.
          </p>
          <div id="hr-sustained" class="mt-4 grid grid-cols-2 gap-3">
            <button
              :for={effort <- @hr["duration_curve"] || []}
              id={"hr-effort-#{effort["duration_s"]}"}
              type="button"
              disabled={is_nil(effort["average_bpm"])}
              phx-click="hr_select"
              phx-value-from={effort["start_s"]}
              phx-value-until={effort["end_s"]}
              class="rounded-2xl border border-[var(--line)] bg-[var(--surface-strong)] p-4 text-left transition enabled:hover:border-[var(--heart-rate)] disabled:opacity-45"
            >
              <span class="text-xs font-bold text-[var(--ink-muted)]">{duration(effort["duration_s"])}</span>
              <strong class="mt-1 block text-xl text-[var(--heart-rate)]">{bpm(effort["average_bpm"])}</strong>
              <span class="mt-1 block text-[10px] text-[var(--ink-muted)]">{if(effort["start_s"],
                do: "#{elapsed_time(effort["start_s"])}–#{elapsed_time(effort["end_s"])} ↗",
                else: "Not enough continuous HR"
              )}</span>
            </button>
          </div>
          <div id="hr-drift" class="mt-4 rounded-2xl border border-[var(--line)] p-4">
            <h4 class="text-sm font-bold">HR–speed drift</h4>
            <%= if @hr["drift"]["available"] do %>
              <p class="mt-2 text-xl font-black">{signed_percent(@hr["drift"]["percent"])}</p>
              <p class="mt-1 text-xs leading-5 text-[var(--ink-muted)]">
                Change in speed per heartbeat between equal halves of a steady, flat window. Positive means less speed per BPM in the second half; not a fitness verdict.
              </p>
              <button
                id="hr-drift-select"
                type="button"
                phx-click="hr_select"
                phx-value-from={@hr["drift"]["start_s"]}
                phx-value-until={@hr["drift"]["end_s"]}
                class="mt-2 min-h-10 text-xs font-bold"
              >Inspect {elapsed_time(@hr["drift"]["start_s"])}–{elapsed_time(@hr["drift"]["end_s"])} →</button>
            <% else %>
              <p class="mt-2 text-xs leading-5 text-[var(--ink-muted)]">{@hr["drift"]["reason"]}</p>
            <% end %>
          </div>
        </div>
      </div>

      <div id="hr-quality" class="topo-card rounded-[1.7rem] p-5 sm:p-6">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h3 class="text-lg font-black">HR data quality</h3>
            <p class="mt-1 text-xs leading-5 text-[var(--ink-muted)]">
              GPS and HR are checked separately. Gaps over 30 seconds are not filled; abrupt transitions stay visible but are excluded from comparisons.
            </p>
          </div>
          <span class="rounded-full bg-[var(--surface-strong)] px-3 py-2 text-xs font-bold">{@quality[
            "suspect_transitions"
          ] || 0} flagged transitions</span>
        </div>
        <p class="mt-3 text-sm text-[var(--ink-muted)]">
          {@quality["missing_samples"] || 0} missing samples · {@quality["invalid_samples"] || 0} invalid readings · {duration(
            @quality["uncovered_s"]
          )} without usable HR
        </p>
        <div :if={@hr["jumps"] != []} class="mt-3 flex flex-wrap gap-2">
          <button
            :for={jump <- Enum.take(@hr["jumps"] || [], 12)}
            id={"hr-jump-#{jump["position"]}"}
            type="button"
            phx-click="hr_select"
            phx-value-from={jump["start_s"]}
            phx-value-until={jump["end_s"]}
            class="min-h-10 rounded-xl border border-[var(--line)] px-3 text-xs font-bold"
          >Inspect {elapsed_time(jump["end_s"])} · {bpm(jump["bpm"])} ↗</button>
        </div>
        <div :if={@hr["zones"] != []} id="hr-zones" class="mt-5 border-t border-[var(--line)] pt-4">
          <h4 class="text-sm font-bold">Configured intensity bands</h4><div class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-5">
            <div :for={zone <- @hr["zones"]} class="rounded-xl bg-[var(--surface-strong)] p-3">
              <p class="text-xs text-[var(--ink-muted)]">
                Z{zone["zone"]} · {zone["lower"]}{if(zone["upper"],
                  do: "–#{zone["upper"] - 1}",
                  else: "+"
                )} BPM
              </p><p class="mt-1 font-black">{duration(zone["seconds"])}</p>
            </div>
          </div><p class="mt-3 text-xs text-[var(--ink-muted)]">
            {compact_number(@hr["load"])} weighted zone-minutes · HR-recorded portions only ·
            <.link navigate={~p"/progress/heart-rate#hr-settings"} class="underline">Manage bands</.link>
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, default: nil

  def hr_stat(assigns) do
    ~H"""
    <div class="min-w-0 rounded-xl bg-[var(--surface-strong)] p-3">
      <dt class="text-[10px] font-bold uppercase tracking-wider text-[var(--ink-muted)]">{@label}</dt><dd class="metric-number mt-1 break-words text-lg font-black">
        {@value}
      </dd><p :if={@note} class="mt-1 text-[10px] text-[var(--ink-muted)]">{@note}</p>
    </div>
    """
  end

  attr :signal, :map, required: true
  attr :id, :string, required: true

  def route_hr(assigns) do
    ~H"""
    <section id={@id} class="topo-card rounded-[1.7rem] p-5 sm:p-6">
      <h3 class="flex items-center gap-2 text-lg font-black">
        <.icon name="hero-heart" class="size-5 text-[var(--heart-rate)]" />Effort on this route
      </h3>
      <p class="mt-1 text-xs text-[var(--ink-muted)]">
        {@signal.eligible_count} eligible / {@signal.recorded_count} HR attempts · same direction and activity
      </p>
      <div class="mt-4 grid gap-4 md:grid-cols-2">
        <div class="rounded-2xl bg-[var(--surface-strong)] p-4">
          <p class="text-xs font-bold text-[var(--ink-muted)]">LATEST PAIR</p>
          <%= if @signal.pair.available do %>
            <h4 class="mt-2 font-black">{@signal.pair.label}</h4><p class="mt-2 text-sm">
              {bpm(@signal.pair.before_bpm)} → {bpm(@signal.pair.after_bpm)} · {signed_percent(
                @signal.pair.speed_delta
              )} speed
            </p>
            <p class="mt-2 text-xs text-[var(--ink-muted)]">
              Median of {@signal.pair.sector_count} shared sectors · ≥{duration(
                @signal.pair.support_s
              )} per attempt
            </p>
            <div class="mt-3 flex flex-wrap gap-3 text-xs font-bold">
              <.link navigate={
                ~p"/tracks/#{@signal.pair.before_id}?#{[hr_from: @signal.pair.before_start_s, hr_until: @signal.pair.before_end_s]}"
              }>Earlier attempt ↗</.link><.link navigate={
                ~p"/tracks/#{@signal.pair.after_id}?#{[hr_from: @signal.pair.after_start_s, hr_until: @signal.pair.after_end_s]}"
              }>Latest attempt ↗</.link>
            </div>
          <% else %>
            <p class="mt-2 text-sm leading-6 text-[var(--ink-muted)]">{@signal.pair.reason}</p>
          <% end %>
        </div>
        <div class="rounded-2xl bg-[var(--surface-strong)] p-4">
          <p class="text-xs font-bold text-[var(--ink-muted)]">LONGER-TERM SIGNAL</p>
          <%= if @signal.trend.available do %>
            <h4 class="mt-2 font-black">{@signal.trend.label}</h4><p class="mt-2 text-sm">
              {signed_bpm(@signal.trend.hr_delta)} HR · {signed_percent(@signal.trend.speed_delta)} speed
            </p>
            <p class="mt-2 text-xs text-[var(--ink-muted)]">
              Latest 3 vs previous 3 · matched sectors · observed variation sets the noise floor.
            </p>
          <% else %>
            <p class="mt-2 text-sm leading-6 text-[var(--ink-muted)]">{@signal.trend.reason}</p>
          <% end %>
        </div>
      </div>
      <p class="mt-4 text-xs leading-5 text-[var(--ink-muted)]">
        The first 5 minutes, the first minute after stops, gaps, and suspect HR are excluded. Similar means within 5% speed or 5 BPM. Wind, temperature, fatigue, traffic, and sensor error can still change the result; this is not a fitness assessment.
      </p>
    </section>
    """
  end

  defp signed_bpm(nil), do: "—"
  defp signed_bpm(value) when abs(value) < 0.5, do: "0 bpm"
  defp signed_bpm(value), do: if(value > 0, do: "+", else: "") <> bpm(value)
  defp signed_percent(value) when abs(value) < 0.5, do: "0%"
  defp signed_percent(value), do: if(value > 0, do: "+", else: "") <> percent(value)
end
