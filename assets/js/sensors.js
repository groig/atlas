// Cadence and speed-sensor charts. Statistics are computed on the server from
// full-resolution points; these hooks only draw them and map samples to the route.
export const createSensorHooks = (echarts, colorsForTheme, dispatchFocus) => {
  const number = (v, digits = 0) => Number.isFinite(v) ? v.toFixed(digits) : "—"
  const nearest = (xs, value) => xs.reduce((best, x, i) => Number.isFinite(x) && (!Number.isFinite(xs[best]) || Math.abs(x - value) < Math.abs(xs[best] - value)) ? i : best, 0)
  const axes = c => ({axisLine: {lineStyle: {color: c.line}}, axisLabel: {color: c.muted}, nameTextStyle: {color: c.muted}, splitLine: {lineStyle: {color: c.line}}})
  const tooltipStyle = c => ({renderMode: "richText", backgroundColor: c.surface, borderColor: c.line, textStyle: {color: c.ink}})
  const observe = h => {
    h.resize = new ResizeObserver(() => h.chart?.resize()); h.resize.observe(h.el)
    h.theme = new MutationObserver(() => h.draw())
    h.theme.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
  }
  const cleanup = h => {h.resize?.disconnect(); h.theme?.disconnect(); h.chart?.dispose()}

  const CadenceChart = {
    mounted() {
      this.axis = "time"; this.active = 0
      this.chart = echarts.init(this.el, null, {renderer: "canvas"})
      this.read(); this.draw(); observe(this)
      this.axisHandler = ({detail}) => {this.axis = detail.axis === "distance" ? "distance" : "time"; this.draw()}
      window.addEventListener("cadence:axis", this.axisHandler)
      this.chart.on("updateAxisPointer", event => {
        const axis = event.axesInfo?.find(a => a.axisDim === "x")
        if(!axis) return
        this.active = nearest(this.xs, Number(axis.value)); this.focus(this.active, "preview")
      })
      this.chart.getZr().on("globalout", () => dispatchFocus({mode: "restore"}))
      this.chart.getZr().on("click", event => {
        const pixel = [event.offsetX, event.offsetY]
        const grid = [0, 1].find(i => this.chart.containPixel({gridIndex: i}, pixel))
        if(grid == null) return
        const [x] = this.chart.convertFromPixel({gridIndex: grid}, pixel)
        this.focus(nearest(this.xs, x), "pin")
      })
      this.el.tabIndex = 0
      this.keyHandler = event => {
        if(event.key === "Escape") {dispatchFocus({mode: "clear"}); return}
        if(!["ArrowLeft", "ArrowRight", "Enter", " "].includes(event.key)) return
        event.preventDefault()
        if(event.key === "ArrowLeft") this.active = Math.max(0, this.active - 1)
        if(event.key === "ArrowRight") this.active = Math.min(this.xs.length - 1, this.active + 1)
        this.focus(this.active, ["Enter", " "].includes(event.key) ? "pin" : "preview")
        this.chart.dispatchAction({type: "showTip", seriesIndex: 0, dataIndex: this.active})
      }
      this.el.addEventListener("keydown", this.keyHandler)
    },
    read() {
      this.series = JSON.parse(this.el.dataset.series || "{}")
      this.origin = Date.parse(this.el.dataset.origin)
      this.seconds = (this.series.time || []).map(t => t ? (Date.parse(t) - this.origin) / 1000 : null)
      this.hasCadence = (this.series.cadence_rpm || []).some(Number.isFinite)
      this.hasDevice = (this.series.sensor_speed_kmh || []).some(Number.isFinite)
    },
    draw() {
      const c = colorsForTheme(), style = axes(c)
      document.querySelectorAll("#cadence-axis-controls button").forEach(b => b.setAttribute("aria-pressed", String(b.id === `cadence-axis-${this.axis}`)))
      this.el.dataset.axis = this.axis
      this.xs = this.axis === "time" ? this.seconds.map(t => t == null ? null : t / 60) : (this.series.distance_km || [])
      const data = key => this.xs.map((x, i) => [x, this.series[key]?.[i] ?? null])
      const max = this.xs.reduce((max, x) => Number.isFinite(x) ? Math.max(max, x) : max, 0)
      const xAxis = gridIndex => ({...style, type: "value", gridIndex, min: 0, max: max || 1, name: this.axis === "time" ? "min" : "km", nameLocation: "middle", nameGap: 27, splitLine: {show: false}, axisPointer: {show: true}, axisLabel: {...style.axisLabel, hideOverlap: true, showMaxLabel: false}})
      const line = (id, name, data, color, xAxisIndex, yAxisIndex, extra = {}) => ({id, name, type: "line", data, xAxisIndex, yAxisIndex, showSymbol: false, connectNulls: false, smooth: false, itemStyle: {color}, lineStyle: {color, width: 1.6}, emphasis: {disabled: true}, ...extra})
      const legend = [this.hasCadence && "Cadence", "GPS speed", this.hasDevice && "Device speed"].filter(Boolean)
      this.chart.setOption({
        animation: false, toolbox: {show: false},
        grid: this.hasCadence ? [{left: 48, right: 24, top: 46, height: "36%"}, {left: 48, right: 24, top: "62%", bottom: 52}] : [{left: 48, right: 24, top: 46, height: 1, show: false}, {left: 48, right: 24, top: 46, bottom: 52}],
        legend: {top: 0, right: 8, textStyle: {color: c.muted}, data: legend},
        tooltip: {trigger: "axis", ...tooltipStyle(c), textStyle: {color: c.ink, rich: {cad: {color: c.cadence}, gps: {color: c.speed}, dev: {color: c.deviceSpeed}}}, formatter: params => {
          const i = nearest(this.xs, Number(params[0]?.axisValue)), s = this.series
          const lines = [`${number(this.seconds[i] / 60, 1)} min · ${number(s.distance_km?.[i], 2)} km`]
          if(this.hasCadence) lines.push(`{cad|●} Cadence  ${number(s.cadence_rpm?.[i])} rpm`)
          lines.push(`{gps|●} GPS speed  ${number(s.speed_kmh?.[i], 1)} km/h`)
          if(this.hasDevice) lines.push(`{dev|●} Device speed  ${number(s.sensor_speed_kmh?.[i], 1)} km/h`)
          if(Number.isFinite(s.grade_percent?.[i])) lines.push(`Grade  ${number(s.grade_percent[i], 1)}%`)
          return lines.join("\n")
        }},
        axisPointer: {link: [{xAxisIndex: "all"}]},
        xAxis: [{...xAxis(0), show: this.hasCadence}, xAxis(1)],
        yAxis: [{...style, type: "value", name: "rpm", min: 0, gridIndex: 0, show: this.hasCadence}, {...style, type: "value", name: "km/h", min: 0, gridIndex: 1}],
        series: [
          line("cadence", "Cadence", this.hasCadence ? data("cadence_rpm") : [], c.cadence, 0, 0, {areaStyle: {color: `${c.cadence}1f`}}),
          line("gps", "GPS speed", data("speed_kmh"), c.speed, 1, 1),
          line("device", "Device speed", this.hasDevice ? data("sensor_speed_kmh") : [], c.deviceSpeed, 1, 1, {lineStyle: {color: c.deviceSpeed, width: 1.6, type: [5, 3]}}),
        ],
      }, true)
    },
    focus(index, mode) {
      if(!this.xs.length) return
      const s = this.series
      dispatchFocus({mode, index, startIndex: Math.max(0, index - 2), endIndex: Math.min(this.xs.length - 1, index + 2), cadence: true, cadenceRpm: s.cadence_rpm?.[index], distanceKm: s.distance_km?.[index], elevationM: s.elevation_m?.[index], speedKmh: s.sensor_speed_kmh?.[index] ?? s.speed_kmh?.[index]})
    },
    updated() {this.read(); this.draw()},
    destroyed() {cleanup(this); window.removeEventListener("cadence:axis", this.axisHandler); this.el.removeEventListener("keydown", this.keyHandler); dispatchFocus({mode: "clear"})},
  }

  const SensorSummaryChart = {
    mounted() {this.chart = echarts.init(this.el); this.draw(); observe(this)},
    draw() {
      const c = colorsForTheme(), style = axes(c), rows = JSON.parse(this.el.dataset.rows || "[]"), kind = this.el.dataset.kind
      const base = {animationDuration: 300, grid: {left: 52, right: 20, top: 30, bottom: 48}, tooltip: {trigger: "axis", ...tooltipStyle(c)}}
      let option = {}
      if(kind === "cadence_bands") {
        option = {
          xAxis: {...style, type: "category", data: rows.map(r => r.label), name: "rpm", nameLocation: "middle", nameGap: 30, axisLabel: {...style.axisLabel, hideOverlap: true}},
          yAxis: {...style, type: "value", name: "min", min: 0},
          tooltip: {...base.tooltip, formatter: ([p]) => {const r = rows[p.dataIndex]; return `${r.label}${r.coasting ? "" : " rpm"}\n${number(r.seconds / 60, 1)} min${Number.isFinite(r.speed_kmh) ? ` · ${number(r.speed_kmh, 1)} km/h avg` : ""}`}},
          series: [{type: "bar", data: rows.map(r => ({value: r.seconds / 60, itemStyle: {color: r.coasting ? c.muted : c.cadence, opacity: r.coasting ? 0.55 : 1, borderRadius: [4, 4, 0, 0]}}))}],
        }
      } else if(kind === "development") {
        // A 2.1 m wheel is typical for 700×25–28c road tyres.
        option = {
          xAxis: {...style, type: "category", data: rows.map(r => r.meters.toFixed(2)), name: "m per pedal stroke", nameLocation: "middle", nameGap: 30, axisLabel: {...style.axisLabel, hideOverlap: true}},
          yAxis: {...style, type: "value", name: "min", min: 0},
          tooltip: {...base.tooltip, formatter: ([p]) => {const r = rows[p.dataIndex]; return `${r.meters.toFixed(2)}–${(r.meters + 0.25).toFixed(2)} m per stroke\n≈ ${(r.meters / 2.1).toFixed(2)}–${((r.meters + 0.25) / 2.1).toFixed(2)} gear ratio on a 2.1 m wheel\n${number(r.seconds / 60, 1)} min`}},
          series: [{type: "bar", barCategoryGap: "12%", data: rows.map(r => r.seconds / 60), itemStyle: {color: c.cadence, borderRadius: [3, 3, 0, 0]}}],
        }
      } else if(kind === "history") {
        option = {
          grid: {...base.grid, right: 52, top: 46},
          legend: {top: 0, textStyle: {color: c.muted}},
          xAxis: {...style, type: "time", splitLine: {show: false}},
          yAxis: [{...style, type: "value", name: "rpm", scale: true}, {...style, type: "value", name: "% coasting", min: 0, max: 100, splitLine: {show: false}}],
          tooltip: {...base.tooltip, formatter: params => {const r = rows[params[0].dataIndex]; return `${r.name}\n${new Date(r.date).toLocaleDateString()}\nCadence ${number(r.average_rpm)} rpm · coasting ${number(r.coasting_percent)}%`}},
          series: [
            {name: "Average cadence", type: "line", data: rows.map(r => [r.date, r.average_rpm]), symbolSize: 7, itemStyle: {color: c.cadence}, lineStyle: {color: c.cadence, width: 2}},
            {name: "Coasting", type: "bar", yAxisIndex: 1, data: rows.map(r => [r.date, r.coasting_percent]), barMaxWidth: 14, itemStyle: {color: c.muted, opacity: 0.35, borderRadius: [3, 3, 0, 0]}},
          ],
        }
      } else if(kind === "calibration") {
        option = {
          xAxis: {...style, type: "category", data: rows.map(r => new Date(r.date).toLocaleDateString()), axisLabel: {...style.axisLabel, hideOverlap: true}},
          yAxis: {...style, type: "value", name: "% vs GPS"},
          tooltip: {...base.tooltip, formatter: ([p]) => {const r = rows[p.dataIndex]; return `${r.name}\nDevice ${r.difference_percent >= 0 ? "+" : ""}${number(r.difference_percent, 1)}% vs GPS`}},
          series: [{type: "bar", barMaxWidth: 22, data: rows.map(r => ({value: r.difference_percent, itemStyle: {color: c.deviceSpeed, borderRadius: r.difference_percent >= 0 ? [3, 3, 0, 0] : [0, 0, 3, 3]}})), markLine: {silent: true, symbol: "none", lineStyle: {color: c.muted, type: "dashed"}, label: {show: false}, data: [{yAxis: 0}]}}],
        }
      }
      this.chart.setOption({...base, ...option}, true)
    },
    updated() {this.draw()},
    destroyed() {cleanup(this)},
  }

  return {CadenceChart, SensorSummaryChart}
}
