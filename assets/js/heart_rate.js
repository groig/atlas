// Statistics use full-resolution server data; these hooks only render and map samples.
export const createHeartRateHooks = (echarts, colorsForTheme, dispatchFocus) => {
  const number = (v, digits = 0) => Number.isFinite(v) ? v.toFixed(digits) : "—"
  const nearest = (xs, value) => xs.reduce((best, x, i) => Number.isFinite(x) && (!Number.isFinite(xs[best]) || Math.abs(x - value) < Math.abs(xs[best] - value)) ? i : best, 0)
  const axes = c => ({axisLine: {lineStyle: {color: c.line}}, axisLabel: {color: c.muted}, nameTextStyle: {color: c.muted}, splitLine: {lineStyle: {color: c.line}}})
  const observe = h => {
    h.resize = new ResizeObserver(() => h.chart?.resize()); h.resize.observe(h.el)
    h.theme = new MutationObserver(() => h.draw())
    h.theme.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
  }
  const cleanup = h => {h.resize?.disconnect(); h.theme?.disconnect(); h.chart?.dispose()}
  const HeartRateChart = {
    mounted() {
      this.axis = "time"; this.selection = null; this.active = 0; this.brushing = false
      this.chart = echarts.init(this.el, null, {renderer: "canvas"})
      this.read(); this.draw(); observe(this)
      this.axisHandler = ({detail}) => {
        this.axis = detail.axis === "distance" ? "distance" : "time"
        document.querySelectorAll("#hr-axis-controls button").forEach(b => b.setAttribute("aria-pressed", String(b.id === `hr-axis-${this.axis}`)))
        this.draw()
      }
      this.brushHandler = () => {
        this.brushing = !this.brushing
        document.getElementById("hr-brush-toggle")?.setAttribute("aria-pressed", String(this.brushing))
        this.chart.dispatchAction({type: "takeGlobalCursor", key: "brush", brushOption: {brushType: this.brushing ? "lineX" : false, brushMode: "single"}})
      }
      window.addEventListener("hr:axis", this.axisHandler); window.addEventListener("hr:brush", this.brushHandler)
      this.handleEvent("hr:selection", range => this.showSelection(range))
      this.handleEvent("hr:clear", () => {this.selection = null; this.chart.dispatchAction({type: "brush", areas: []}); this.draw(); dispatchFocus({mode: "clear"})})
      this.chart.on("updateAxisPointer", event => {
        const axis = event.axesInfo?.find(a => a.axisDim === "x")
        if(!axis || this.brushing) return
        this.active = nearest(this.xs, Number(axis.value)); this.focus(this.active, "preview")
      })
      this.chart.getZr().on("globalout", () => dispatchFocus({mode: "restore"}))
      this.chart.getZr().on("click", event => {
        if(this.brushing) return
        const pixel = [event.offsetX, event.offsetY]
        const grid = [0, 1].find(i => this.chart.containPixel({gridIndex: i}, pixel))
        if(grid == null) return
        const [x] = this.chart.convertFromPixel({gridIndex: grid}, pixel)
        this.focus(nearest(this.xs, x), "pin")
      })
      this.chart.on("brushEnd", event => {
        const range = event.areas?.[0]?.coordRange
        if(!range) return
        const values = range.map(x => this.axis === "time" ? x * 60 : this.seconds[nearest(this.xs, x)]).sort((a, b) => a - b)
        const from = Math.max(0, values[0]), until = Math.min(this.duration, values[1])
        if(until > from) this.pushEvent("hr_select", {from, until})
      })
      this.el.tabIndex = 0
      this.keyHandler = event => {
        if(event.key === "Escape") {this.pushEvent("hr_clear", {}); return}
        if(!["ArrowLeft", "ArrowRight", "Enter", " "].includes(event.key)) return
        event.preventDefault()
        if(event.key === "ArrowLeft") this.active = Math.max(0, this.active - 1)
        if(event.key === "ArrowRight") this.active = Math.min(this.xs.length - 1, this.active + 1)
        this.focus(this.active, ["Enter", " "].includes(event.key) ? "pin" : "preview")
        this.chart.dispatchAction({type: "showTip", seriesIndex: 1, dataIndex: this.active})
      }
      this.el.addEventListener("keydown", this.keyHandler); this.initialSelection()
    },
    read() {
      this.series = JSON.parse(this.el.dataset.series || "{}")
      this.origin = Date.parse(this.el.dataset.origin)
      this.seconds = (this.series.time || []).map(t => t ? (Date.parse(t) - this.origin) / 1000 : null)
      this.duration = this.seconds.reduce((max, t) => Number.isFinite(t) ? Math.max(max, t) : max, 0)
    },
    initialSelection() {
      const selection = JSON.parse(this.el.dataset.selection || "null")
      if(selection) this.showSelection({from: selection.start_s, until: selection.end_s})
    },
    draw() {
      const c = colorsForTheme(), style = axes(c)
      document.querySelectorAll("#hr-axis-controls button").forEach(b => b.setAttribute("aria-pressed", String(b.id === `hr-axis-${this.axis}`)))
      document.getElementById("hr-brush-toggle")?.setAttribute("aria-pressed", String(this.brushing))
      this.el.dataset.axis = this.axis
      this.xs = this.axis === "time" ? this.seconds.map(t => t == null ? null : t / 60) : (this.series.distance_km || [])
      const data = key => this.xs.map((x, i) => [x, this.series[key]?.[i] ?? null])
      const hr = data("heart_rate_bpm").flatMap((p, i) => this.series.hr_break?.[i] && i > 0 ? [[p[0], null], p] : [p])
      const max = this.xs.reduce((max, x) => Number.isFinite(x) ? Math.max(max, x) : max, 0)
      const xAxis = gridIndex => ({...style, type: "value", gridIndex, min: 0, max: max || 1, name: this.axis === "time" ? "min" : "km", nameLocation: "middle", nameGap: 27, splitLine: {show: false}, axisPointer: {show: true}, axisLabel: {...style.axisLabel, hideOverlap: true, showMaxLabel: false}})
      const line = (id, name, data, color, xAxisIndex, yAxisIndex) => ({id, name, type: "line", data, xAxisIndex, yAxisIndex, showSymbol: false, connectNulls: false, smooth: false, itemStyle: {color}, lineStyle: {color, width: 2}, emphasis: {disabled: true}})
      this.chart.setOption({
        animation: false, color: [c.heartRate, c.speed, c.elevation],
        toolbox: {show: false},
        grid: [{left: 48, right: 50, top: 46, height: "36%"}, {left: 48, right: 50, top: "62%", bottom: 52}],
        legend: {top: 0, right: 8, textStyle: {color: c.muted}, data: ["Heart rate", "Speed", "Elevation"]},
        tooltip: {trigger: "axis", renderMode: "richText", backgroundColor: c.surface, borderColor: c.line, textStyle: {color: c.ink, rich: {hr: {color: c.heartRate}, speed: {color: c.speed}, elevation: {color: c.elevation}}}, formatter: params => {
          const i = nearest(this.xs, Number(params[0]?.axisValue)), s = this.series
          return `${number(this.seconds[i] / 60, 1)} min · ${number(s.distance_km?.[i], 2)} km\n{hr|●} Heart rate  ${number(s.heart_rate_bpm?.[i])} bpm${s.hr_jump?.[i] ? " · flagged" : ""}\n{speed|●} Speed  ${number(s.speed_kmh?.[i], 1)} km/h\n{elevation|●} Elevation  ${number(s.elevation_m?.[i])} m`
        }},
        axisPointer: {link: [{xAxisIndex: "all"}]},
        brush: {toolbox: [], xAxisIndex: [0, 1], brushMode: "single", brushType: "lineX", throttleType: "debounce", throttleDelay: 200, brushStyle: {color: `${c.heartRate}22`, borderColor: c.heartRate}},
        xAxis: [xAxis(0), xAxis(1)],
        yAxis: [{...style, type: "value", name: "BPM", scale: true, gridIndex: 0}, {...style, type: "value", name: "km/h", gridIndex: 1, min: 0}, {...style, type: "value", name: "m", gridIndex: 1, scale: true, splitLine: {show: false}}],
        series: [
          {...line("hr", "Heart rate", hr, c.heartRate, 0, 0), areaStyle: {color: `${c.heartRate}14`}, markPoint: {symbol: "circle", symbolSize: 7, label: {show: false}, data: this.xs.flatMap((x, i) => this.series.hr_jump?.[i] && Number.isFinite(this.series.heart_rate_bpm?.[i]) ? [{coord: [x, this.series.heart_rate_bpm[i]]}] : [])}},
          line("speed", "Speed", data("speed_kmh"), c.speed, 1, 1), line("elevation", "Elevation", data("elevation_m"), c.elevation, 1, 2),
        ],
      }, true)
      if(this.selection) this.paintSelection()
      if(this.brushing) this.chart.dispatchAction({type: "takeGlobalCursor", key: "brush", brushOption: {brushType: "lineX", brushMode: "single"}})
    },
    focus(index, mode, range = null) {
      if(!this.xs.length) return
      const s = this.series
      dispatchFocus({mode, index, startIndex: range?.[0] ?? Math.max(0, index - 2), endIndex: range?.[1] ?? Math.min(this.xs.length - 1, index + 2), heartRateBpm: s.heart_rate_bpm?.[index], heartRate: true, distanceKm: s.distance_km?.[index], elevationM: s.elevation_m?.[index], speedKmh: s.speed_kmh?.[index]})
    },
    showSelection(range) {
      this.selection = range; this.chart.dispatchAction({type: "brush", areas: []}); this.paintSelection()
      const first = nearest(this.seconds, range.from), last = nearest(this.seconds, range.until)
      this.focus(last, "pin", [Math.min(first, last), Math.max(first, last)])
    },
    paintSelection() {
      const {from, until} = this.selection
      const a = this.axis === "time" ? from / 60 : this.xs[nearest(this.seconds, from)]
      const b = this.axis === "time" ? until / 60 : this.xs[nearest(this.seconds, until)]
      const markArea = {silent: true, itemStyle: {color: `${colorsForTheme().heartRate}22`}, data: [[{xAxis: a}, {xAxis: b}]]}
      this.chart.setOption({series: [{id: "hr", markArea}, {id: "speed", markArea}]})
    },
    updated() {this.read(); this.draw(); this.initialSelection()},
    destroyed() {cleanup(this); window.removeEventListener("hr:axis", this.axisHandler); window.removeEventListener("hr:brush", this.brushHandler); this.el.removeEventListener("keydown", this.keyHandler); dispatchFocus({mode: "clear"})},
  }
  const HeartRateSummaryChart = {
    mounted() {this.chart = echarts.init(this.el); this.draw(); observe(this)},
    draw() {
      const c = colorsForTheme(), style = axes(c), rows = JSON.parse(this.el.dataset.rows || "[]"), kind = this.el.dataset.kind
      let labels = [], series = [], name = "minutes", legend = false
      if(kind === "distribution") {
        labels = rows.map(r => r.label)
        series = [{name: "Recorded minutes", type: "bar", data: rows.map(r => r.seconds / 60), itemStyle: {color: c.heartRate, borderRadius: [4, 4, 0, 0]}}]
      } else if(kind === "cumulative") {
        labels = rows.map(r => r.bpm)
        let total = rows.reduce((sum, r) => sum + r.seconds, 0)
        const data = rows.map(r => {const value = total / 60; total -= r.seconds; return value})
        series = [{name: "Time at or above BPM", type: "line", showSymbol: false, data, itemStyle: {color: c.heartRate}, lineStyle: {color: c.heartRate}, areaStyle: {color: `${c.heartRate}18`}}]
      } else if(kind === "weekly") {
        labels = rows.map(r => r.week)
        const bands = [...new Set(rows.flatMap(r => r.distribution.map(b => b.bpm)))].sort((a, b) => a - b)
        series = bands.map((bpm, i) => ({name: `${bpm}–${bpm + 9} BPM`, type: "bar", stack: "HR", data: rows.map(r => r.tracks ? (r.distribution.find(b => b.bpm === bpm)?.seconds || 0) / 60 : null), itemStyle: {color: c.heartRate, opacity: 0.3 + 0.7 * (i + 1) / bands.length}}))
        legend = true
      } else if(kind === "load") {
        labels = rows.map(r => r.date)
        series = [7, 28].map((days, i) => ({name: `${days}-day recorded load`, type: "line", showSymbol: false, data: rows.map(r => r[`load_${days}`]), itemStyle: {color: i ? c.elevation : c.heartRate}, lineStyle: {color: i ? c.elevation : c.heartRate}}))
        name = "zone-minutes"; legend = true
      } else if(kind === "compare") {
        const bands = [...new Set(rows.flatMap(r => r.distribution.map(b => b.bpm)))].sort((a, b) => a - b)
        labels = bands.map(bpm => `${bpm}–${bpm + 9}`)
        const palette = [c.heartRate, c.elevation, c.speed, c.ink]
        series = rows.map((r, i) => ({name: r.name, type: "bar", data: bands.map(bpm => r.available ? (r.distribution.find(b => b.bpm === bpm)?.seconds || 0) / 60 : null), itemStyle: {color: palette[i]}}))
        legend = true
      }
      this.chart.setOption({animationDuration: 250, grid: {left: 55, right: 20, top: legend ? 66 : 30, bottom: 48}, tooltip: {trigger: "axis", renderMode: "richText", backgroundColor: c.surface, borderColor: c.line, textStyle: {color: c.ink}, valueFormatter: v => Number.isFinite(v) ? `${v.toFixed(1)} ${name}` : "Unavailable"}, legend: {show: legend, type: "scroll", top: 0, textStyle: {color: c.muted}}, xAxis: {...style, type: "category", data: labels, name: ["distribution", "cumulative", "compare"].includes(kind) ? "BPM" : "", nameLocation: "middle", nameGap: 30, axisLabel: {...style.axisLabel, hideOverlap: true}}, yAxis: {...style, type: "value", name, min: 0}, series}, true)
    },
    updated() {this.draw()},
    destroyed() {cleanup(this)},
  }
  return {HeartRateChart, HeartRateSummaryChart}
}
