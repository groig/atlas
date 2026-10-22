defmodule TrackAnalyzerWeb.SensorComponents do
  @moduledoc "Cadence and speed-sensor displays shared by track and progress views."
  use TrackAnalyzerWeb, :html

  @doc "True when a track has any cadence or device-speed readings."
  def sensors?(track) do
    (get_in(track.stats, ["cadence", "sample_count"]) || 0) > 0 or
      (get_in(track.stats, ["speed_sensor", "sample_count"]) || 0) > 0
  end

  @doc "Cadence bands with coasting first, ready for the summary chart."
  def cadence_rows(cadence) do
    coasting =
      if (cadence["coasting_s"] || 0) > 0,
        do: [%{"label" => "Coasting", "seconds" => cadence["coasting_s"], "coasting" => true}],
        else: []

    bands =
      for bin <- cadence["histogram"] || [] do
        %{
          "label" => "#{bin["rpm"]}–#{bin["rpm"] + 9}",
          "seconds" => bin["seconds"],
          "speed_kmh" => bin["speed_kmh"]
        }
      end

    coasting ++ bands
  end

  attr :track, :map, required: true
  attr :series, :string, required: true

  def track_sensors(assigns) do
    assigns =
      assigns
      |> assign(:cadence, assigns.track.stats["cadence"] || %{})
      |> assign(:speed, assigns.track.stats["speed_sensor"] || %{})

    assigns =
      assigns
      |> assign(:cadence?, (assigns.cadence["sample_count"] || 0) > 0)
      |> assign(:speed?, (assigns.speed["sample_count"] || 0) > 0)

    ~H"""
    <section id="track-sensors" class="mt-5 space-y-5">
      <div class="topo-card overflow-hidden rounded-[1.7rem] p-5 sm:p-6">
        <header class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <p class="flex items-center gap-2 text-xs font-bold uppercase tracking-[0.15em] text-[var(--cadence)]">
              <.icon name="hero-arrow-path" class="size-4" />Pedaling & sensors
            </p>
            <h2 class="mt-1 text-2xl font-black">
              {cond do
                @cadence? and @speed? -> "Cadence and device speed"
                @cadence? -> "Cadence"
                true -> "Device speed"
              end}
            </h2>
            <p class="mt-2 text-sm text-[var(--ink-muted)]">
              <span :if={@cadence?}>
                {duration(@cadence["pedaling_s"])} pedaling · {percent(@cadence["coverage_percent"])} cadence coverage
              </span>
              <span :if={@cadence? and @speed?}> · </span>
              <span :if={@speed?}>{percent(@speed["coverage_percent"])} device-speed coverage</span>
            </p>
          </div>
          <.link
            :if={@cadence?}
            id="track-cadence-progress"
            navigate={~p"/progress/pedaling"}
            class="inline-flex min-h-11 items-center gap-2 text-sm font-bold transition hover:text-[var(--cadence)]"
          >Pedaling progress <.icon name="hero-arrow-up-right" class="size-4" /></.link>
        </header>

        <dl :if={@cadence?} id="cadence-stats" class="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
          <.sensor_stat
            label="Average cadence"
            value={rpm(@cadence["average_rpm"])}
            note={"#{rpm(@cadence["moving_average_rpm"])} including coasting"}
          />
          <.sensor_stat
            label="Coasting"
            value={percent(@cadence["coasting_percent"])}
            note={"#{duration(@cadence["coasting_s"])} of moving time"}
          />
          <.sensor_stat
            label="Peak cadence"
            value={rpm(@cadence["maximum_rpm"])}
            note="single reading"
          />
          <.sensor_stat
            label="Pedal strokes"
            value={compact_number(@cadence["revolutions"])}
            note="crank revolutions"
          />
        </dl>

        <dl
          :if={@speed?}
          id="device-speed-stats"
          class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4"
        >
          <.sensor_stat
            label="Device distance"
            value={distance(@speed["distance_m"])}
            note={"GPS #{distance(@speed["gps_distance_m"])} over the same time"}
          />
          <.sensor_stat
            label="Device vs GPS"
            value={percent_change(@speed["distance_difference_percent"])}
            note={
              if(@speed["distance_difference_percent"],
                do: "distance difference",
                else: "needs 1 km of shared coverage"
              )
            }
          />
          <.sensor_stat
            label="Device max speed"
            value={kmh(@speed["maximum_kmh"])}
            note="single reading"
          />
          <.sensor_stat
            label="Device moving speed"
            value={kmh(@speed["average_moving_kmh"])}
            note={"over #{duration(@speed["moving_s"])}"}
          />
        </dl>

        <div class="mt-6 flex flex-wrap items-center justify-between gap-3">
          <div
            id="cadence-axis-controls"
            class="flex gap-1 rounded-xl border border-[var(--line)] p-1"
            aria-label="Chart horizontal axis"
          >
            <button
              :for={{label, axis} <- [{"Time", "time"}, {"Distance", "distance"}]}
              id={"cadence-axis-#{axis}"}
              type="button"
              aria-pressed={to_string(axis == "time")}
              phx-click={JS.dispatch("cadence:axis", detail: %{axis: axis})}
              class="min-h-10 rounded-lg px-3 text-xs font-bold transition aria-pressed:bg-[var(--ink)] aria-pressed:text-[var(--canvas)]"
            >{label}</button>
          </div>
          <p class="text-xs text-[var(--ink-muted)]">Hover to trace on the map · tap to pin</p>
        </div>
        <div
          id="cadence-chart"
          phx-hook="CadenceChart"
          phx-update="ignore"
          data-series={@series}
          data-origin={@track.started_at && DateTime.to_iso8601(@track.started_at)}
          class="echarts-surface mt-3 h-[28rem]"
          role="img"
          aria-label="Cadence over the ride, with device speed compared to GPS speed. Use the arrow keys to step through readings."
        >
        </div>
      </div>

      <div :if={@cadence?} class="grid grid-cols-1 gap-5 lg:grid-cols-3">
        <div class="topo-card min-w-0 rounded-[1.7rem] p-5 sm:p-6">
          <h3 class="text-lg font-black">Time by cadence</h3>
          <p class="mt-1 text-xs leading-5 text-[var(--ink-muted)]">
            Moving time in 10 rpm bands. Coasting means rolling without pedaling.
          </p>
          <div
            id="cadence-distribution"
            phx-hook="SensorSummaryChart"
            phx-update="ignore"
            data-kind="cadence_bands"
            data-rows={json(cadence_rows(@cadence))}
            class="echarts-surface mt-3 h-64"
            role="img"
            aria-label="Moving time spent coasting and in each ten rpm cadence band"
          >
          </div>
        </div>

        <div class="topo-card min-w-0 rounded-[1.7rem] p-5 sm:p-6">
          <h3 class="text-lg font-black">Gearing fingerprint</h3>
          <p class="mt-1 text-xs leading-5 text-[var(--ink-muted)]">
            Distance covered per pedal stroke. Each gear gives its own value, so peaks show the gears you rode most.
          </p>
          <div
            id="cadence-development"
            phx-hook="SensorSummaryChart"
            phx-update="ignore"
            data-kind="development"
            data-rows={json(@cadence["development"] || [])}
            class="echarts-surface mt-3 h-64"
            role="img"
            aria-label="Pedaling time by metres travelled per crank revolution"
          >
          </div>
          <p :if={@cadence["development_mode_m"]} class="text-xs text-[var(--ink-muted)]">
            Most used: about
            <strong class="text-[var(--ink)]">{meters(@cadence["development_mode_m"])} per stroke</strong>
            · uses {if(@speed?, do: "device", else: "GPS")} speed
          </p>
        </div>

        <div class="topo-card min-w-0 rounded-[1.7rem] p-5 sm:p-6">
          <h3 class="text-lg font-black">Cadence by terrain</h3>
          <p class="mt-1 text-xs leading-5 text-[var(--ink-muted)]">
            Grade over 100 m windows. Average cadence counts pedaling time only.
          </p>
          <ul id="cadence-terrain" class="mt-4 space-y-2">
            <li
              :for={band <- @cadence["terrain"] || []}
              id={"cadence-terrain-#{band["band"]}"}
              class={[
                "rounded-xl bg-[var(--surface-strong)] p-3",
                band["seconds"] == 0 && "opacity-45"
              ]}
            >
              <div class="flex items-baseline justify-between gap-3">
                <span class="text-sm font-bold">{band["label"]}</span>
                <span class="metric-number text-lg font-black text-[var(--cadence)]">{rpm(
                  band["average_rpm"]
                )}</span>
              </div>
              <div class="mt-2 h-1.5 overflow-hidden rounded-full bg-[var(--line)]">
                <div
                  class="h-full rounded-full bg-[var(--cadence)] transition-all duration-500"
                  style={"width: #{min(100 - (band["coasting_percent"] || 100), 100)}%"}
                >
                </div>
              </div>
              <p class="mt-1.5 text-[11px] text-[var(--ink-muted)]">
                {duration(band["seconds"])} · {percent(band["coasting_percent"])} coasting · {kmh(
                  band["speed_kmh"]
                )}
              </p>
            </li>
          </ul>
        </div>
      </div>

      <div :if={@speed?} id="speed-sensor-check" class="topo-card rounded-[1.7rem] p-5 sm:p-6">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="max-w-2xl">
            <h3 class="text-lg font-black">Device speed vs GPS</h3>
            <p class="mt-1 text-xs leading-5 text-[var(--ink-muted)]">
              Device speed comes from a wheel sensor when one is paired, otherwise from the recorder's own GPS. Distances, speeds and splits elsewhere use GPS.
            </p>
          </div>
          <span class="rounded-full bg-[var(--surface-strong)] px-3 py-2 text-xs font-bold">
            {percent(@speed["within_10_percent"])} of moving time within 10%
          </span>
        </div>
        <div class="mt-4 grid gap-3 md:grid-cols-3">
          <div class="rounded-2xl bg-[var(--surface-strong)] p-4">
            <p class="text-[10px] font-bold uppercase tracking-wider text-[var(--ink-muted)]">
              Typical gap
            </p>
            <p class="metric-number mt-1 text-xl font-black">
              {kmh(@speed["median_difference_kmh"])}
            </p>
            <p class="mt-1 text-xs text-[var(--ink-muted)]">
              median difference over {duration(@speed["compared_s"])} compared
            </p>
          </div>
          <div class="rounded-2xl bg-[var(--surface-strong)] p-4">
            <p class="text-[10px] font-bold uppercase tracking-wider text-[var(--ink-muted)]">
              Wheel calibration
            </p>
            <p id="speed-sensor-calibration" class="mt-1 text-sm font-semibold leading-6">
              {calibration_hint(@speed)}
            </p>
          </div>
          <div class="rounded-2xl bg-[var(--surface-strong)] p-4">
            <p class="text-[10px] font-bold uppercase tracking-wider text-[var(--ink-muted)]">
              GPS gaps covered
            </p>
            <p class="metric-number mt-1 text-xl font-black">{duration(@speed["gps_gap_s"])}</p>
            <p class="mt-1 text-xs text-[var(--ink-muted)]">
              moving time where GPS was rejected but the device kept reading
            </p>
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc "Plain-language wheel-size advice from a device/GPS distance ratio."
  def calibration_hint(%{"calibration_factor" => factor, "distance_difference_percent" => diff})
      when is_number(factor) and is_number(diff) do
    cond do
      abs(diff) < 1 ->
        "Device and GPS agree within 1%. No change needed."

      diff > 0 ->
        "Device read #{percent_change(diff)} long. If it uses a wheel sensor, try a wheel circumference #{number(abs(1 - factor) * 100)}% smaller (×#{number(factor, 3)})."

      true ->
        "Device read #{percent_change(diff)} short. If it uses a wheel sensor, try a wheel circumference #{number(abs(1 - factor) * 100)}% larger (×#{number(factor, 3)})."
    end
  end

  def calibration_hint(_speed),
    do: "Needs at least 1 km where both device and GPS distance were recorded."

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, default: nil

  def sensor_stat(assigns) do
    ~H"""
    <div class="min-w-0 rounded-xl bg-[var(--surface-strong)] p-3 transition hover:-translate-y-0.5">
      <dt class="text-[10px] font-bold uppercase tracking-wider text-[var(--ink-muted)]">{@label}</dt><dd class="metric-number mt-1 break-words text-lg font-black">
        {@value}
      </dd><p :if={@note} class="mt-1 text-[10px] text-[var(--ink-muted)]">{@note}</p>
    </div>
    """
  end

  def kmh(nil), do: "—"
  def kmh(value), do: number(value, 1) <> " km/h"

  def meters(nil), do: "—"
  def meters(value), do: number(value, 2) <> " m"

  defp number(value, decimals \\ 1),
    do: :erlang.float_to_binary(value * 1.0, decimals: decimals)
end
