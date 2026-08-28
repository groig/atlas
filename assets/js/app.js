// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/track_analyzer"
import topbar from "../vendor/topbar"
import L from "leaflet"
import "leaflet.heat"
import polyline from "@mapbox/polyline"
import * as echarts from "echarts"
import {ShareCard} from "./share_card"

const systemTheme = () => matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
const setTheme = theme => {
  const resolved = theme === "system" ? systemTheme() : theme
  document.documentElement.setAttribute("data-theme", resolved)
  document.documentElement.setAttribute("data-theme-source", theme)
  if(theme === "system") localStorage.removeItem("track-atlas:theme")
  else localStorage.setItem("track-atlas:theme", theme)
}

setTheme(localStorage.getItem("track-atlas:theme") || "system")
window.addEventListener("phx:cycle-theme", () => {
  const current = document.documentElement.getAttribute("data-theme")
  setTheme(current === "dark" ? "light" : "dark")
})
window.addEventListener("storage", event => {
  if(event.key === "track-atlas:theme") setTheme(event.newValue || "system")
})
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if(document.documentElement.getAttribute("data-theme-source") === "system") setTheme("system")
})

const tileLayer = element => L.tileLayer(element.dataset.tileUrl, {
  attribution: element.dataset.attribution,
  maxZoom: 19,
})

const markerIcon = kind => L.divIcon({
  className: "",
  html: `<span class="track-map-marker" data-kind="${kind}"></span>`,
  iconSize: [18, 18],
  iconAnchor: [9, 9],
})

const profileFocusEvent = "track-atlas:profile-focus"
const dispatchProfileFocus = detail => window.dispatchEvent(new CustomEvent(profileFocusEvent, {detail}))

const profileMetric = (value, unit, precision = 1) =>
  Number.isFinite(value) ? `${Number(value).toFixed(precision)} ${unit}` : null

const profileFocusTooltip = (focus, pinned) => {
  const values = [
    profileMetric(focus.distanceKm, "km", 2),
    profileMetric(focus.elevationM, "m"),
    profileMetric(focus.speedKmh, "km/h"),
  ].filter(Boolean)
  const state = pinned ? `<span class="track-focus-state">Pinned</span>` : ""
  return `${state}<strong>${values.shift() || "Track position"}</strong>${values.length > 0 ? `<span>${values.join(" · ")}</span>` : ""}`
}

const TrackMap = {
  mounted() {
    if(this.focusHandler) window.removeEventListener(profileFocusEvent, this.focusHandler)
    this.map?.remove()
    this.el.replaceChildren()
    this.points = polyline.decode(this.el.dataset.polyline || "")
    this.pinnedFocus = null
    this.cursor = null
    this.focusCasing = null
    this.focusLine = null
    this.map = L.map(this.el, {zoomControl: true, preferCanvas: true})
    tileLayer(this.el).addTo(this.map)

    if(this.points.length > 0) {
      this.line = L.polyline(this.points, {color: chartColors().speed, weight: 5, opacity: 0.92, lineJoin: "round"}).addTo(this.map)
      this.map.fitBounds(this.line.getBounds(), {padding: [24, 24], maxZoom: 16})
      L.marker(this.points[0], {icon: markerIcon("start")}).addTo(this.map)
      L.marker(this.points[this.points.length - 1], {icon: markerIcon("finish")}).addTo(this.map)
    } else {
      this.map.setView([20, 0], 2)
    }

    this.focusHandler = ({detail}) => {
      switch(detail.mode) {
        case "preview":
          this.renderFocus(detail, false)
          break
        case "pin":
          this.pinnedFocus = {...detail, mode: "pin"}
          this.renderFocus(this.pinnedFocus, true)
          break
        case "restore":
          if(this.pinnedFocus) this.renderFocus(this.pinnedFocus, true)
          else this.clearFocus()
          break
        case "clear":
          this.pinnedFocus = null
          this.clearFocus()
          break
      }
    }
    window.addEventListener(profileFocusEvent, this.focusHandler)
    requestAnimationFrame(() => this.map.invalidateSize())
  },
  renderFocus(focus, pinned) {
    const index = Math.max(0, Math.min(focus.index, this.points.length - 1))
    const point = this.points[index]
    if(!point) return

    const start = Math.max(0, Math.min(focus.startIndex, index))
    const end = Math.min(this.points.length - 1, Math.max(focus.endIndex, index))
    let corridor = this.points.slice(start, end + 1)
    if(corridor.length < 2) corridor = this.points.slice(Math.max(index - 1, 0), Math.min(index + 2, this.points.length))

    const colors = chartColors()
    if(!this.focusCasing) {
      this.focusCasing = L.polyline(corridor, {color: colors.focusCasing, weight: 11, opacity: 0.72, lineCap: "round", lineJoin: "round", interactive: false}).addTo(this.map)
      this.focusLine = L.polyline(corridor, {color: colors.accent, weight: 6, opacity: 1, lineCap: "round", lineJoin: "round", interactive: false}).addTo(this.map)
    } else {
      this.focusCasing.setLatLngs(corridor).setStyle({color: colors.focusCasing})
      this.focusLine.setLatLngs(corridor).setStyle({color: colors.accent})
    }

    if(!this.cursor) {
      this.cursor = L.marker(point, {icon: markerIcon(pinned ? "pinned" : "cursor"), interactive: false}).addTo(this.map)
      this.cursor.bindTooltip("", {permanent: true, direction: "top", offset: [0, -10], className: "track-focus-tooltip"})
    } else {
      this.cursor.setLatLng(point).setIcon(markerIcon(pinned ? "pinned" : "cursor"))
    }

    this.cursor.setTooltipContent(profileFocusTooltip(focus, pinned)).openTooltip()
    this.focusCasing.bringToFront()
    this.focusLine.bringToFront()
    this.cursor.setZIndexOffset(1000)
    this.line?.setStyle({opacity: 0.38})
  },
  clearFocus() {
    this.cursor?.remove()
    this.focusCasing?.remove()
    this.focusLine?.remove()
    this.cursor = null
    this.focusCasing = null
    this.focusLine = null
    this.line?.setStyle({opacity: 0.92})
  },
  updated() { this.mounted() },
  destroyed() {
    window.removeEventListener(profileFocusEvent, this.focusHandler)
    this.map?.remove()
  },
}

const HeatMap = {
  mounted() {
    this.map?.remove()
    this.el.replaceChildren()
    const cells = JSON.parse(this.el.dataset.cells || "[]")
    this.map = L.map(this.el, {zoomControl: true, preferCanvas: true})
    tileLayer(this.el).addTo(this.map)

    if(cells.length > 0) {
      const maximum = Math.max(...cells.map(cell => cell.weight), 1)
      const points = cells.map(cell => [cell.latitude, cell.longitude, Math.max(cell.weight / maximum, 0.08)])
      L.heatLayer(points, {radius: 17, blur: 22, minOpacity: 0.3, gradient: {0.15: "#27d9c2", 0.55: "#d8ff45", 1: "#ff6f3d"}}).addTo(this.map)
      this.map.fitBounds(L.latLngBounds(points.map(([lat, lon]) => [lat, lon])), {padding: [20, 20], maxZoom: 13})
    } else {
      this.map.setView([20, 0], 2)
    }
    requestAnimationFrame(() => this.map.invalidateSize())
  },
  updated() { this.mounted() },
  destroyed() { this.map?.remove() },
}

const chartColors = () => ({
  ink: getComputedStyle(document.documentElement).getPropertyValue("--ink").trim(),
  muted: getComputedStyle(document.documentElement).getPropertyValue("--ink-muted").trim(),
  line: getComputedStyle(document.documentElement).getPropertyValue("--line").trim(),
  elevation: getComputedStyle(document.documentElement).getPropertyValue("--cyan").trim(),
  speed: getComputedStyle(document.documentElement).getPropertyValue("--orange").trim(),
  accent: getComputedStyle(document.documentElement).getPropertyValue("--accent").trim(),
  focusCasing: getComputedStyle(document.documentElement).getPropertyValue("--ink").trim(),
})

const nearestProfileIndex = (distances, value) => {
  const numeric = Number(value)
  if(!Number.isFinite(numeric) || distances.length === 0) return null

  return distances.reduce((nearest, distance, index) =>
    Math.abs(distance - numeric) < Math.abs(distances[nearest] - numeric) ? index : nearest
  , 0)
}

const profileIndexForAxisValue = (distances, value) => {
  const numeric = Number(value)
  if(!Number.isFinite(numeric)) return null
  if(Number.isInteger(numeric) && numeric >= 0 && numeric < distances.length) return numeric
  return nearestProfileIndex(distances, numeric)
}

const profileFocus = (series, requestedIndex, mode) => {
  const distances = series.distance_km || []
  if(distances.length === 0) return null

  const index = Math.max(0, Math.min(Math.round(requestedIndex), distances.length - 1))
  const distanceKm = distances[index]
  if(!Number.isFinite(distanceKm)) return null

  let startIndex = index
  let endIndex = index
  while(startIndex > 0 && distanceKm - distances[startIndex - 1] <= 0.1) startIndex -= 1
  while(endIndex < distances.length - 1 && distances[endIndex + 1] - distanceKm <= 0.1) endIndex += 1

  if(startIndex === endIndex) {
    startIndex = Math.max(index - 1, 0)
    endIndex = Math.min(index + 1, distances.length - 1)
  }

  return {
    mode,
    index,
    startIndex,
    endIndex,
    distanceKm,
    elevationM: (series.elevation_m || [])[index],
    speedKmh: (series.speed_kmh || [])[index],
    time: (series.time || [])[index],
  }
}

const TrackChart = {
  mounted() {
    this.cleanup()
    const series = JSON.parse(this.el.dataset.series || "{}")
    const colors = chartColors()
    this.activeIndex = null
    this.pinnedIndex = null
    this.chart = echarts.init(this.el, null, {renderer: "canvas"})
    this.chart.setOption({
      animationDuration: 650,
      color: [colors.elevation, colors.speed],
      grid: {left: 48, right: 18, top: 30, bottom: 42},
      tooltip: {trigger: "axis", triggerOn: "mousemove|click", valueFormatter: value => value == null ? "—" : value},
      legend: {top: 0, right: 60, textStyle: {color: colors.muted}},
      xAxis: {type: "category", data: series.distance_km || [], name: "km", boundaryGap: false, axisLine: {lineStyle: {color: colors.line}}, axisLabel: {color: colors.muted}},
      yAxis: [
        {type: "value", name: "elevation m", scale: true, splitLine: {lineStyle: {color: colors.line}}, axisLabel: {color: colors.muted}},
        {type: "value", name: "km/h", scale: true, splitLine: {show: false}, axisLabel: {color: colors.muted}},
      ],
      series: [
        {name: "Elevation", type: "line", data: series.elevation_m || [], symbol: "none", smooth: 0.18, itemStyle: {color: colors.elevation}, lineStyle: {width: 2, color: colors.elevation}, areaStyle: {color: `${colors.elevation}21`}},
        {name: "Speed", type: "line", yAxisIndex: 1, data: series.speed_kmh || [], symbol: "none", smooth: 0.15, itemStyle: {color: colors.speed}, lineStyle: {width: 2, color: colors.speed}},
      ],
    })

    this.axisPointerHandler = event => {
      const xAxis = event.axesInfo?.find(axis => axis.axisDim === "x")
      const index =
        xAxis?.seriesDataIndices?.[0]?.dataIndexInside ??
        xAxis?.seriesDataIndices?.[0]?.dataIndex ??
        profileIndexForAxisValue(series.distance_km || [], xAxis?.value)
      if(!Number.isInteger(index)) return

      this.activeIndex = index
      const focus = profileFocus(series, index, "preview")
      if(focus) dispatchProfileFocus(focus)
    }
    this.chart.on("updateAxisPointer", this.axisPointerHandler)

    this.zr = this.chart.getZr()
    this.clickHandler = event => {
      if(!this.chart.containPixel({gridIndex: 0}, [event.offsetX, event.offsetY])) return

      const axisValue = this.chart.convertFromPixel({xAxisIndex: 0}, event.offsetX)
      const index = profileIndexForAxisValue(series.distance_km || [], axisValue) ?? this.activeIndex
      if(!Number.isInteger(index)) return

      if(this.pinnedIndex === index) {
        this.pinnedIndex = null
        dispatchProfileFocus({mode: "clear"})
        this.chart.dispatchAction({type: "hideTip"})
      } else {
        this.pinnedIndex = index
        const focus = profileFocus(series, index, "pin")
        if(focus) dispatchProfileFocus(focus)
      }
    }
    this.globalOutHandler = () => dispatchProfileFocus({mode: "restore"})
    this.zr.on("click", this.clickHandler)
    this.zr.on("globalout", this.globalOutHandler)

    this.keyHandler = event => {
      if(event.key !== "Escape") return
      this.pinnedIndex = null
      dispatchProfileFocus({mode: "clear"})
      this.chart.dispatchAction({type: "hideTip"})
    }
    window.addEventListener("keydown", this.keyHandler)
    this.resize = () => this.chart.resize()
    window.addEventListener("resize", this.resize)
  },
  updated() { this.mounted() },
  cleanup() {
    if(this.resize) window.removeEventListener("resize", this.resize)
    if(this.keyHandler) window.removeEventListener("keydown", this.keyHandler)
    if(this.axisPointerHandler) this.chart?.off("updateAxisPointer", this.axisPointerHandler)
    if(this.clickHandler) this.zr?.off("click", this.clickHandler)
    if(this.globalOutHandler) this.zr?.off("globalout", this.globalOutHandler)
    this.chart?.dispose()
  },
  destroyed() {
    this.cleanup()
    dispatchProfileFocus({mode: "clear"})
  },
}

const MonthlyChart = {
  mounted() {
    if(this.resize) window.removeEventListener("resize", this.resize)
    this.chart?.dispose()
    const rows = JSON.parse(this.el.dataset.monthly || "[]")
    const colors = chartColors()
    this.chart = echarts.init(this.el, null, {renderer: "canvas"})
    this.chart.setOption({
      grid: {left: 46, right: 14, top: 18, bottom: 38},
      tooltip: {trigger: "axis"},
      xAxis: {type: "category", data: rows.map(row => row.month), axisLabel: {color: colors.muted}, axisLine: {lineStyle: {color: colors.line}}},
      yAxis: {type: "value", name: "km", axisLabel: {color: colors.muted}, splitLine: {lineStyle: {color: colors.line}}},
      series: [{type: "bar", data: rows.map(row => Math.round(row.distance_m / 100) / 10), itemStyle: {color: "#b7df24", borderRadius: [7, 7, 0, 0]}}],
    })
    this.resize = () => this.chart.resize()
    window.addEventListener("resize", this.resize)
  },
  updated() { this.mounted() },
  destroyed() {
    window.removeEventListener("resize", this.resize)
    this.chart?.dispose()
  },
}

const SpeedHistoryChart = {
  mounted() {
    if(this.resize) window.removeEventListener("resize", this.resize)
    this.chart?.dispose()
    const history = JSON.parse(this.el.dataset.history || "{}")
    const rows = history.points || []
    const colors = chartColors()
    const samples = rows.filter(row => row.metric_mps != null).map(row => ({
      value: [row.started_at, row.metric_mps],
      name: row.name,
      confidence: row.confidence,
    }))

    this.chart = echarts.init(this.el, null, {renderer: "canvas"})
    this.chart.setOption({
      animationDuration: 700,
      color: ["#ff6f3d", "#27bca9", "#b7df24"],
      grid: {left: 62, right: 30, top: 48, bottom: 54},
      legend: {top: 5, right: 10, textStyle: {color: colors.muted}},
      tooltip: {
        trigger: "axis",
        axisPointer: {type: "line", lineStyle: {color: colors.muted, opacity: 0.35}},
        formatter: params => {
          const point = params.find(param => param.seriesName === "Every track")?.data
          const date = params[0]?.value?.[0] ? new Date(params[0].value[0]).toLocaleDateString(undefined, {month: "short", day: "numeric", year: "numeric"}) : ""
          const values = params.map(param => `<div style="display:flex;justify-content:space-between;gap:24px"><span>${param.marker}${param.seriesName}</span><strong>${param.value[1] == null ? "—" : Number(param.value[1]).toFixed(1) + " km/h"}</strong></div>`).join("")
          const confidence = history.metric === "instantaneous" && point?.confidence ? `<div style="margin-top:6px;opacity:.65">${point.confidence} confidence</div>` : ""
          return `<strong>${point?.name || date}</strong><div style="opacity:.65;margin:2px 0 7px">${date}</div>${values}${confidence}`
        },
      },
      xAxis: {
        type: "time",
        axisLine: {lineStyle: {color: colors.line}},
        axisLabel: {color: colors.muted, hideOverlap: true},
        splitLine: {show: false},
      },
      yAxis: {
        type: "value",
        name: "km/h",
        scale: true,
        axisLabel: {color: colors.muted},
        splitLine: {lineStyle: {color: colors.line}},
      },
      series: [
        {
          name: "Every track",
          type: "scatter",
          data: samples,
          symbolSize: 9,
          itemStyle: {color: "#ff6f3d", borderColor: colors.ink, borderWidth: 1},
          emphasis: {scale: 1.7},
          z: 4,
        },
        {
          name: "Rolling median",
          type: "line",
          data: rows.filter(row => row.rolling_median_mps != null).map(row => [row.started_at, row.rolling_median_mps]),
          symbol: "none",
          smooth: 0.28,
          lineStyle: {width: 3, color: "#27bca9"},
          z: 3,
        },
        {
          name: "Record",
          type: "line",
          data: rows.filter(row => row.record_mps != null).map(row => [row.started_at, row.record_mps]),
          symbol: "none",
          step: "end",
          lineStyle: {width: 2, color: "#b7df24", type: "dashed"},
          z: 2,
        },
      ],
    })
    this.resize = () => this.chart.resize()
    window.addEventListener("resize", this.resize)
  },
  updated() { this.mounted() },
  destroyed() {
    window.removeEventListener("resize", this.resize)
    this.chart?.dispose()
  },
}

const ProgressVolumeChart = {
  mounted() {
    if(this.resize) window.removeEventListener("resize", this.resize)
    this.chart?.dispose()
    const volume = JSON.parse(this.el.dataset.volume || "{}")
    const rows = volume.weeks || []
    const colors = chartColors()
    this.chart = echarts.init(this.el, null, {renderer: "canvas"})
    this.chart.setOption({
      animationDuration: 650,
      grid: {left: 54, right: 18, top: 24, bottom: 42},
      tooltip: {
        trigger: "axis",
        formatter: params => {
          const row = rows[params[0]?.dataIndex]
          if(!row) return ""
          const date = new Date(`${row.week}T00:00:00`).toLocaleDateString(undefined, {month: "short", day: "numeric"})
          return `<strong>Week of ${date}</strong><div style="margin-top:7px">${(row.distance_m / 1000).toFixed(1)} km · ${row.track_count} track${row.track_count === 1 ? "" : "s"}</div>`
        },
      },
      xAxis: {
        type: "category",
        data: rows.map(row => row.week),
        axisLabel: {color: colors.muted, formatter: value => new Date(`${value}T00:00:00`).toLocaleDateString(undefined, {month: "short", day: "numeric"}), hideOverlap: true},
        axisLine: {lineStyle: {color: colors.line}},
      },
      yAxis: {
        type: "value",
        name: "km",
        axisLabel: {color: colors.muted},
        splitLine: {lineStyle: {color: colors.line}},
      },
      series: [{
        name: "Distance",
        type: "bar",
        data: rows.map(row => Math.round(row.distance_m / 100) / 10),
        itemStyle: {color: colors.accent, borderRadius: [7, 7, 2, 2]},
        emphasis: {itemStyle: {color: colors.speed}},
      }],
    })
    this.resize = () => this.chart.resize()
    window.addEventListener("resize", this.resize)
  },
  updated() { this.mounted() },
  destroyed() {
    window.removeEventListener("resize", this.resize)
    this.chart?.dispose()
  },
}

const routeSectorEvent = "track-atlas:route-sector"
const dispatchRouteSector = (sector, mode = "preview") =>
  window.dispatchEvent(new CustomEvent(routeSectorEvent, {detail: {sector, mode}}))

window.addEventListener("route-sector:select", event => dispatchRouteSector(Number(event.detail?.sector), "pin"))

const routeSectorColor = direction => {
  if(direction === "faster") return "#34c784"
  if(direction === "slower") return "#ff8752"
  return "#27d9c2"
}

const RouteProgressMap = {
  mounted() {
    if(this.focusHandler) window.removeEventListener(routeSectorEvent, this.focusHandler)
    this.map?.remove()
    this.el.replaceChildren()
    this.points = polyline.decode(this.el.dataset.polyline || "")
    this.sectors = JSON.parse(this.el.dataset.sectors || "[]")
    this.lines = []
    this.pinnedSector = null
    this.map = L.map(this.el, {zoomControl: true, preferCanvas: true})
    tileLayer(this.el).addTo(this.map)

    if(this.points.length > 0) {
      const cumulative = [0]
      for(let index = 1; index < this.points.length; index += 1) {
        const prior = L.latLng(this.points[index - 1])
        const current = L.latLng(this.points[index])
        cumulative.push(cumulative[index - 1] + prior.distanceTo(current))
      }
      const totalDistance = cumulative[cumulative.length - 1]
      const indexAtDistance = target => {
        const found = cumulative.findIndex(distance => distance >= target)
        return found === -1 ? this.points.length - 1 : found
      }

      for(let index = 0; index < 10; index += 1) {
        const start = indexAtDistance(totalDistance * index / 10)
        const end = Math.max(indexAtDistance(totalDistance * (index + 1) / 10), start + 1)
        const segment = this.points.slice(start, Math.min(end + 1, this.points.length))
        const sector = this.sectors[index] || {direction: "steady"}
        const line = L.polyline(segment, {
          color: routeSectorColor(sector.direction),
          weight: 6,
          opacity: 0.9,
          lineCap: "round",
          lineJoin: "round",
        }).addTo(this.map)
        line.on("mouseover", () => dispatchRouteSector(index + 1, "preview"))
        line.on("mouseout", () => dispatchRouteSector(this.pinnedSector, this.pinnedSector ? "pin" : "clear"))
        line.on("click", () => {
          this.pinnedSector = this.pinnedSector === index + 1 ? null : index + 1
          dispatchRouteSector(this.pinnedSector, this.pinnedSector ? "pin" : "clear")
        })
        this.lines.push(line)
      }
      this.map.fitBounds(L.latLngBounds(this.points), {padding: [24, 24], maxZoom: 16})
      L.marker(this.points[0], {icon: markerIcon("start")}).addTo(this.map)
      L.marker(this.points[this.points.length - 1], {icon: markerIcon("finish")}).addTo(this.map)
    } else {
      this.map.setView([20, 0], 2)
    }

    this.focusHandler = ({detail}) => {
      if(detail.mode === "pin") this.pinnedSector = detail.sector
      if(detail.mode === "clear") this.pinnedSector = null
      this.lines.forEach((line, index) => {
        const active = detail.sector === index + 1
        line.setStyle({weight: active ? 11 : 6, opacity: active ? 1 : (detail.sector ? 0.28 : 0.9)})
        if(active) line.bringToFront()
      })
    }
    window.addEventListener(routeSectorEvent, this.focusHandler)
    requestAnimationFrame(() => this.map.invalidateSize())
  },
  updated() { this.mounted() },
  destroyed() {
    window.removeEventListener(routeSectorEvent, this.focusHandler)
    this.map?.remove()
  },
}

const RouteSectorChart = {
  mounted() {
    this.cleanup()
    const rows = JSON.parse(this.el.dataset.sectors || "[]")
    const colors = chartColors()
    this.chart = echarts.init(this.el, null, {renderer: "canvas"})
    this.chart.setOption({
      animationDuration: 650,
      grid: {left: 48, right: 16, top: 22, bottom: 38},
      tooltip: {
        trigger: "axis",
        formatter: params => {
          const row = rows[params[0]?.dataIndex]
          if(!row) return ""
          const delta = row.delta_percent == null ? "—" : `${row.delta_percent > 0 ? "+" : ""}${row.delta_percent.toFixed(1)}%`
          return `<strong>Sector ${row.number}</strong><div style="margin-top:7px">Latest ${row.latest_speed_mps == null ? "—" : (row.latest_speed_mps * 3.6).toFixed(1) + " km/h"}</div><div>Prior median ${row.baseline_speed_mps == null ? "—" : (row.baseline_speed_mps * 3.6).toFixed(1) + " km/h"}</div><div style="margin-top:4px"><strong>${delta}</strong></div>`
        },
      },
      xAxis: {type: "category", data: rows.map(row => `S${row.number}`), axisLabel: {color: colors.muted}, axisLine: {lineStyle: {color: colors.line}}},
      yAxis: {type: "value", name: "%", axisLabel: {color: colors.muted}, splitLine: {lineStyle: {color: colors.line}}},
      series: [{
        type: "bar",
        data: rows.map(row => ({value: row.delta_percent, itemStyle: {color: routeSectorColor(row.direction), borderRadius: row.delta_percent >= 0 ? [6, 6, 0, 0] : [0, 0, 6, 6]}})),
        markArea: {silent: true, itemStyle: {color: `${colors.muted}10`}, data: [[{yAxis: -2}, {yAxis: 2}]]},
      }],
    })
    this.overHandler = params => dispatchRouteSector(params.dataIndex + 1, "preview")
    this.outHandler = () => dispatchRouteSector(null, "clear")
    this.clickHandler = params => dispatchRouteSector(params.dataIndex + 1, "pin")
    this.chart.on("mouseover", this.overHandler)
    this.chart.on("mouseout", this.outHandler)
    this.chart.on("click", this.clickHandler)
    this.focusHandler = ({detail}) => {
      this.chart.dispatchAction({type: "downplay", seriesIndex: 0})
      if(detail.sector) this.chart.dispatchAction({type: "highlight", seriesIndex: 0, dataIndex: detail.sector - 1})
    }
    window.addEventListener(routeSectorEvent, this.focusHandler)
    this.resize = () => this.chart.resize()
    window.addEventListener("resize", this.resize)
  },
  updated() { this.mounted() },
  cleanup() {
    if(this.resize) window.removeEventListener("resize", this.resize)
    if(this.focusHandler) window.removeEventListener(routeSectorEvent, this.focusHandler)
    if(this.overHandler) this.chart?.off("mouseover", this.overHandler)
    if(this.outHandler) this.chart?.off("mouseout", this.outHandler)
    if(this.clickHandler) this.chart?.off("click", this.clickHandler)
    this.chart?.dispose()
  },
  destroyed() { this.cleanup() },
}

const RouteTrendChart = {
  mounted() {
    if(this.resize) window.removeEventListener("resize", this.resize)
    this.chart?.dispose()
    const rows = JSON.parse(this.el.dataset.history || "[]")
    const colors = chartColors()
    this.chart = echarts.init(this.el, null, {renderer: "canvas"})
    this.chart.setOption({
      animationDuration: 650,
      grid: {left: 60, right: 24, top: 28, bottom: 50},
      tooltip: {
        trigger: "axis",
        formatter: params => {
          const row = rows[params[0]?.dataIndex]
          if(!row) return ""
          const date = new Date(row.started_at).toLocaleDateString(undefined, {month: "short", day: "numeric", year: "numeric"})
          return `<strong>${row.name}</strong><div style="opacity:.65;margin:2px 0 7px">${date}</div><div>${row.avg_speed_kmh.toFixed(1)} km/h · ${row.distance_km.toFixed(1)} km</div><div style="margin-top:5px;opacity:.65">Click to open track</div>`
        },
      },
      xAxis: {type: "time", axisLabel: {color: colors.muted}, axisLine: {lineStyle: {color: colors.line}}, splitLine: {show: false}},
      yAxis: {type: "value", name: "km/h", scale: true, axisLabel: {color: colors.muted}, splitLine: {lineStyle: {color: colors.line}}},
      series: [{
        type: "line",
        data: rows.map(row => ({value: [row.started_at, row.avg_speed_kmh], trackId: row.track_id, name: row.name})),
        symbolSize: 10,
        showSymbol: true,
        smooth: 0.18,
        lineStyle: {width: 3, color: colors.speed},
        itemStyle: {color: colors.accent, borderColor: colors.ink, borderWidth: 2},
        emphasis: {scale: 1.5},
      }],
    })
    this.clickHandler = params => {
      if(params.data?.trackId) window.location.assign(`/tracks/${params.data.trackId}`)
    }
    this.chart.on("click", this.clickHandler)
    this.resize = () => this.chart.resize()
    window.addEventListener("resize", this.resize)
  },
  updated() { this.mounted() },
  destroyed() {
    window.removeEventListener("resize", this.resize)
    if(this.clickHandler) this.chart?.off("click", this.clickHandler)
    this.chart?.dispose()
  },
}

const CompareChart = {
  mounted() {
    if(this.resize) window.removeEventListener("resize", this.resize)
    this.chart?.dispose()
    const rows = JSON.parse(this.el.dataset.comparison || "[]")
    const colors = chartColors()
    const maxima = [
      Math.max(...rows.map(row => row.distance_km), 1),
      Math.max(...rows.map(row => row.moving_hours), 1),
      Math.max(...rows.map(row => row.avg_speed_kmh), 1),
      Math.max(...rows.map(row => row.elevation_gain_m), 1),
      100,
    ]
    this.chart = echarts.init(this.el, null, {renderer: "canvas"})
    this.chart.setOption({
      color: ["#ff6f3d", "#27bca9", "#b7df24", "#8873ff"],
      legend: {bottom: 0, textStyle: {color: colors.muted}},
      tooltip: {},
      radar: {
        radius: "66%",
        center: ["50%", "45%"],
        splitArea: {areaStyle: {color: ["transparent"]}},
        splitLine: {lineStyle: {color: colors.line}},
        axisLine: {lineStyle: {color: colors.line}},
        axisName: {color: colors.muted},
        indicator: [
          {name: "Distance", max: maxima[0]},
          {name: "Duration", max: maxima[1]},
          {name: "Speed", max: maxima[2]},
          {name: "Climbing", max: maxima[3]},
          {name: "Quality", max: maxima[4]},
        ],
      },
      series: [{type: "radar", data: rows.map(row => ({name: row.name, value: [row.distance_km, row.moving_hours, row.avg_speed_kmh, row.elevation_gain_m, row.quality_score], areaStyle: {opacity: 0.08}}))}],
    })
    this.resize = () => this.chart.resize()
    window.addEventListener("resize", this.resize)
  },
  updated() { this.mounted() },
  destroyed() {
    window.removeEventListener("resize", this.resize)
    this.chart?.dispose()
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, TrackMap, HeatMap, TrackChart, MonthlyChart, SpeedHistoryChart, ProgressVolumeChart, RouteProgressMap, RouteSectorChart, RouteTrendChart, CompareChart, ShareCard},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
