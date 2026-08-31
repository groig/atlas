const WIDTH = 1080
const HEIGHT = 1920
const DAY_MS = 86_400_000
const FONT = 'Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'

const palette = {
  canvas: "#0c1310",
  surface: "#142019",
  surfaceStrong: "#1a2920",
  ink: "#eff7f0",
  muted: "#93a59a",
  line: "rgba(219, 241, 226, 0.14)",
  accent: "#d8ff45",
  accentInk: "#152008",
  cyan: "#36e3cd",
  orange: "#ff8752",
}

const periodBounds = (period, now = new Date()) => {
  const year = now.getFullYear()
  const month = now.getMonth()
  let from = null
  let until = null

  switch(period) {
    case "week": {
      const mondayOffset = (now.getDay() + 6) % 7
      from = new Date(year, month, now.getDate() - mondayOffset)
      until = new Date(from.getFullYear(), from.getMonth(), from.getDate() + 7)
      break
    }
    case "month":
      from = new Date(year, month, 1)
      until = new Date(year, month + 1, 1)
      break
    case "year":
      from = new Date(year, 0, 1)
      until = new Date(year + 1, 0, 1)
      break
  }

  return {from, until}
}

const periodLabel = (period, bounds, now = new Date()) => {
  switch(period) {
    case "week": {
      const end = new Date(bounds.until.getTime() - DAY_MS)
      const startLabel = bounds.from.toLocaleDateString(undefined, {month: "short", day: "numeric"})
      const endLabel = end.toLocaleDateString(undefined, {month: "short", day: "numeric", year: "numeric"})
      return `THIS WEEK · ${startLabel} — ${endLabel}`.toUpperCase()
    }
    case "month":
      return now.toLocaleDateString(undefined, {month: "long", year: "numeric"}).toUpperCase()
    case "year":
      return `THIS YEAR · ${now.getFullYear()}`
    default:
      return "ALL TIME"
  }
}

const periodFilename = (period, bounds, now = new Date()) => {
  const dateKey = date => [date.getFullYear(), String(date.getMonth() + 1).padStart(2, "0"), String(date.getDate()).padStart(2, "0")].join("-")

  switch(period) {
    case "week": return `track-atlas-week-${dateKey(bounds.from)}.png`
    case "month": return `track-atlas-${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}.png`
    case "year": return `track-atlas-${now.getFullYear()}.png`
    default: return "track-atlas-all-time.png"
  }
}

const localDateKey = date => [date.getFullYear(), String(date.getMonth() + 1).padStart(2, "0"), String(date.getDate()).padStart(2, "0")].join("-")
const monthKey = date => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`

const recapRhythm = (period, activity, bounds) => {
  const rows = activity.map(row => ({...row, date: new Date(row.started_at)})).filter(row => !Number.isNaN(row.date.getTime()))
  let buckets = []
  let keyFor = localDateKey

  if(period === "week") {
    buckets = Array.from({length: 7}, (_, index) => {
      const date = new Date(bounds.from.getFullYear(), bounds.from.getMonth(), bounds.from.getDate() + index)
      return {key: localDateKey(date), label: date.toLocaleDateString(undefined, {weekday: "narrow"}), showLabel: true}
    })
  } else if(period === "month") {
    const days = Math.round((bounds.until - bounds.from) / DAY_MS)
    buckets = Array.from({length: days}, (_, index) => {
      const date = new Date(bounds.from.getFullYear(), bounds.from.getMonth(), index + 1)
      return {key: localDateKey(date), label: String(index + 1), showLabel: index === 0 || (index + 1) % 5 === 0 || index === days - 1}
    })
  } else if(period === "year") {
    keyFor = monthKey
    buckets = Array.from({length: 12}, (_, index) => {
      const date = new Date(bounds.from.getFullYear(), index, 1)
      return {key: monthKey(date), label: date.toLocaleDateString(undefined, {month: "narrow"}), showLabel: true}
    })
  } else {
    keyFor = date => String(date.getFullYear())
    const years = [...new Set(rows.map(row => row.date.getFullYear()))].sort((left, right) => left - right)
    buckets = years.map(year => ({key: String(year), label: String(year), showLabel: true}))
  }

  const totals = rows.reduce((result, row) => {
    const key = keyFor(row.date)
    result[key] = (result[key] || 0) + Number(row.distance_m || 0)
    return result
  }, {})

  return buckets.map(bucket => ({...bucket, distanceM: totals[bucket.key] || 0}))
}

const activeDayCount = activity => new Set(
  activity
    .map(row => new Date(row.started_at))
    .filter(date => !Number.isNaN(date.getTime()))
    .map(localDateKey)
).size

const compact = (value, precision = 1) => {
  if(!Number.isFinite(Number(value))) return "—"
  const number = Number(value)
  if(Math.abs(number) >= 1_000_000) return `${(number / 1_000_000).toFixed(precision)}m`
  if(Math.abs(number) >= 1_000) return `${(number / 1_000).toFixed(precision)}k`
  return number.toFixed(precision)
}

const distance = meters => {
  if(!Number.isFinite(Number(meters))) return "—"
  if(meters >= 1_000) return `${compact(meters / 1_000, meters >= 1_000_000 ? 0 : 1)} km`
  return `${Math.round(meters)} m`
}

const elevation = meters => {
  if(!Number.isFinite(Number(meters))) return "—"
  if(meters >= 10_000) return `${compact(meters / 1_000, 1)} km`
  return `${Math.round(meters).toLocaleString()} m`
}

const speed = metersPerSecond => Number.isFinite(Number(metersPerSecond)) ? `${(metersPerSecond * 3.6).toFixed(1)} km/h` : "—"

const duration = seconds => {
  if(!Number.isFinite(Number(seconds))) return "—"
  const totalMinutes = Math.max(Math.round(seconds / 60), 0)
  const hours = Math.floor(totalMinutes / 60)
  const minutes = totalMinutes % 60
  if(hours > 0) return `${hours}h ${String(minutes).padStart(2, "0")}m`
  return `${minutes}m`
}

const roundedRect = (context, x, y, width, height, radius) => {
  const r = Math.min(radius, width / 2, height / 2)
  context.beginPath()
  context.moveTo(x + r, y)
  context.arcTo(x + width, y, x + width, y + height, r)
  context.arcTo(x + width, y + height, x, y + height, r)
  context.arcTo(x, y + height, x, y, r)
  context.arcTo(x, y, x + width, y, r)
  context.closePath()
}

const fillRoundRect = (context, x, y, width, height, radius, fill) => {
  roundedRect(context, x, y, width, height, radius)
  context.fillStyle = fill
  context.fill()
}

const font = (context, weight, size) => {
  context.font = `${weight} ${size}px ${FONT}`
}

const fitText = (context, text, maximumWidth, weight, maximumSize, minimumSize = 32) => {
  let size = maximumSize
  font(context, weight, size)
  while(size > minimumSize && context.measureText(text).width > maximumWidth) {
    size -= 2
    font(context, weight, size)
  }
  return size
}

const label = (context, text, x, y, color = palette.muted, size = 24) => {
  font(context, 800, size)
  context.fillStyle = color
  context.fillText(text.toUpperCase(), x, y)
}

const drawBrand = context => {
  fillRoundRect(context, 72, 70, 74, 74, 22, palette.accent)
  context.strokeStyle = palette.accentInk
  context.lineWidth = 5
  context.lineJoin = "round"
  context.beginPath()
  context.moveTo(94, 96)
  context.lineTo(107, 90)
  context.lineTo(122, 98)
  context.lineTo(122, 122)
  context.lineTo(108, 114)
  context.lineTo(94, 121)
  context.closePath()
  context.stroke()

  font(context, 900, 34)
  context.fillStyle = palette.ink
  context.fillText("Track / Atlas", 170, 118)
}

const drawBackground = context => {
  context.fillStyle = palette.canvas
  context.fillRect(0, 0, WIDTH, HEIGHT)

  const glow = context.createRadialGradient(880, 90, 0, 880, 90, 620)
  glow.addColorStop(0, "rgba(216, 255, 69, 0.18)")
  glow.addColorStop(1, "rgba(216, 255, 69, 0)")
  context.fillStyle = glow
  context.fillRect(0, 0, WIDTH, 760)

  context.strokeStyle = "rgba(219, 241, 226, 0.055)"
  context.lineWidth = 2
  for(let offset = -HEIGHT; offset < WIDTH; offset += 72) {
    context.beginPath()
    context.moveTo(offset, 0)
    context.lineTo(offset + HEIGHT, HEIGHT)
    context.stroke()
  }

  context.strokeStyle = "rgba(54, 227, 205, 0.10)"
  for(let index = 0; index < 4; index += 1) {
    context.beginPath()
    context.ellipse(940, 420, 210 + index * 55, 330 + index * 65, -0.35, 0, Math.PI * 2)
    context.stroke()
  }
}

const drawMetricCard = (context, x, y, width, height, title, value, accent) => {
  fillRoundRect(context, x, y, width, height, 30, palette.surface)
  context.fillStyle = accent
  context.fillRect(x, y, 8, height)
  label(context, title, x + 30, y + 76, palette.muted, 20)
  fitText(context, value, width - 60, 900, 48, 30)
  context.fillStyle = palette.ink
  context.fillText(value, x + 30, y + 151)
}

const drawSpeedLedger = (context, summary) => {
  const x = 72
  const y = 835
  const width = 936
  const height = 286
  fillRoundRect(context, x, y, width, height, 38, palette.surface)
  label(context, "Speed ledger", x + 36, y + 52, palette.orange, 22)

  const values = [
    ["Moving avg", speed(summary.avg_speed_mps)],
    [`Instant max · ${summary.max_speed_confidence || "unrated"}`, speed(summary.max_speed_mps)],
    ["Best 100 m", speed(summary.best_100m_speed_mps)],
    ["Best 500 m", speed(summary.best_500m_speed_mps)],
  ]
  const columnWidth = (width - 72) / values.length

  values.forEach(([title, value], index) => {
    const columnX = x + 36 + index * columnWidth
    if(index > 0) {
      context.fillStyle = palette.line
      context.fillRect(columnX - 18, y + 93, 2, 130)
    }
    label(context, title, columnX, y + 122, palette.muted, 16)
    fitText(context, value, columnWidth - 32, 900, 34, 23)
    context.fillStyle = palette.ink
    context.fillText(value, columnX, y + 179)
  })
}

const drawRhythm = (context, rhythm, activeDays, period) => {
  const x = 72
  const y = 1150
  const width = 936
  const height = 330
  fillRoundRect(context, x, y, width, height, 38, palette.surfaceStrong)
  label(context, "Activity rhythm", x + 36, y + 52, palette.cyan, 22)
  font(context, 650, 18)
  context.fillStyle = palette.muted
  context.fillText(period === "all" ? "Distance by year" : period === "year" ? "Distance by month" : "Distance by day", x + 36, y + 88)
  font(context, 900, 44)
  context.fillStyle = palette.ink
  context.fillText(String(activeDays), x + width - 190, y + 62)
  font(context, 700, 17)
  context.fillStyle = palette.muted
  context.fillText(activeDays === 1 ? "ACTIVE DAY" : "ACTIVE DAYS", x + width - 190, y + 92)

  const plotX = x + 36
  const plotY = y + 126
  const plotWidth = width - 72
  const plotHeight = 135
  const maximum = Math.max(...rhythm.map(bucket => bucket.distanceM), 1)
  const gap = rhythm.length > 20 ? 5 : 10
  const barWidth = Math.max((plotWidth - gap * Math.max(rhythm.length - 1, 0)) / Math.max(rhythm.length, 1), 4)

  if(rhythm.length === 0) {
    font(context, 650, 24)
    context.fillStyle = palette.muted
    context.fillText("Dated tracks will build your rhythm.", plotX, plotY + 70)
  }

  rhythm.forEach((bucket, index) => {
    const height = Math.max(bucket.distanceM / maximum * plotHeight, bucket.distanceM > 0 ? 8 : 2)
    const barX = plotX + index * (barWidth + gap)
    fillRoundRect(context, barX, plotY + plotHeight - height, barWidth, height, Math.min(9, barWidth / 2), bucket.distanceM > 0 ? palette.cyan : "rgba(147, 165, 154, 0.18)")
    if(bucket.showLabel) {
      font(context, 700, rhythm.length > 16 ? 13 : 16)
      context.fillStyle = palette.muted
      context.textAlign = "center"
      context.fillText(bucket.label, barX + barWidth / 2, plotY + plotHeight + 34)
      context.textAlign = "left"
    }
  })

}

const drawHighlights = (context, summary) => {
  const x = 72
  const y = 1510
  const width = 936
  const height = 228
  label(context, "Period highlights", x, y + 26, palette.accent, 22)
  const rows = [
    ["Longest outing", distance(summary.longest_distance_m)],
    ["Biggest climb", elevation(summary.highest_elevation_gain_m)],
    ["Longest moving", duration(summary.longest_moving_s)],
  ]
  const columnWidth = width / rows.length

  rows.forEach(([title, value], index) => {
    const columnX = x + index * columnWidth
    fillRoundRect(context, columnX, y + 55, columnWidth - 16, height - 55, 30, palette.surface)
    label(context, title, columnX + 26, y + 101, palette.muted, 17)
    fitText(context, value, columnWidth - 68, 900, 39, 25)
    context.fillStyle = palette.ink
    context.fillText(value, columnX + 26, y + 158)
  })
}

const drawEmpty = (context, period) => {
  label(context, "Your movement, in numbers", 72, 302, palette.accent, 24)
  fitText(context, "NO TRACKS IN THIS PERIOD", 900, 900, 92, 56)
  context.fillStyle = palette.ink
  context.fillText("NO TRACKS IN THIS PERIOD", 72, 430)
  font(context, 600, 34)
  context.fillStyle = palette.muted
  context.fillText("Choose another period after more tracks are analyzed.", 72, 500)
  fillRoundRect(context, 72, 610, 936, 760, 52, palette.surface)
  context.strokeStyle = palette.line
  context.lineWidth = 4
  context.setLineDash([14, 18])
  roundedRect(context, 132, 670, 816, 640, 42)
  context.stroke()
  context.setLineDash([])
  font(context, 900, 220)
  context.textAlign = "center"
  context.fillStyle = palette.accent
  context.fillText("0", WIDTH / 2, 1040)
  font(context, 800, 28)
  context.fillStyle = palette.muted
  context.fillText(period === "all" ? "ANALYZED TRACKS" : "TRACKS IN THIS CALENDAR PERIOD", WIDTH / 2, 1100)
  context.textAlign = "left"
}

const renderRecap = (canvas, summary, period, bounds, now = new Date()) => {
  const context = canvas.getContext("2d")
  canvas.width = WIDTH
  canvas.height = HEIGHT
  drawBackground(context)
  drawBrand(context)

  const periodText = periodLabel(period, bounds, now)
  fitText(context, periodText, 430, 800, 22, 17)
  context.fillStyle = palette.muted
  context.textAlign = "right"
  context.fillText(periodText, WIDTH - 72, 116)
  context.textAlign = "left"

  if(summary.track_count === 0) {
    drawEmpty(context, period)
  } else {
    const activity = summary.activity || []
    const rhythm = recapRhythm(period, activity, bounds)
    const activeDays = activeDayCount(activity)

    label(context, "Your movement, in numbers", 72, 250, palette.accent, 24)
    const hero = distance(summary.distance_m)
    fitText(context, hero, 936, 900, 128, 72)
    context.fillStyle = palette.ink
    context.fillText(hero, 72, 390)
    font(context, 650, 29)
    context.fillStyle = palette.muted
    context.fillText("DISTANCE EXPLORED", 76, 442)

    drawMetricCard(context, 72, 520, 296, 230, "Tracks", Number(summary.track_count).toLocaleString(), palette.accent)
    drawMetricCard(context, 392, 520, 296, 230, "Moving", duration(summary.moving_s), palette.cyan)
    drawMetricCard(context, 712, 520, 296, 230, "Elevation", elevation(summary.elevation_gain_m), palette.orange)
    drawSpeedLedger(context, summary)
    drawRhythm(context, rhythm, activeDays, period)
    drawHighlights(context, summary)
  }

  canvas.setAttribute("aria-label", `${periodText}. ${summary.track_count} analyzed tracks, ${distance(summary.distance_m)} explored.`)
}

const canvasBlob = canvas => new Promise((resolve, reject) => {
  canvas.toBlob(blob => blob ? resolve(blob) : reject(new Error("Could not create the PNG.")), "image/png")
})

export const ShareCard = {
  mounted() {
    this.root = this.el.closest("#share-card-generator")
    this.periodButtons = [...this.root.querySelectorAll("[data-share-period]")]
    this.status = this.root.querySelector("#share-recap-status")
    this.loading = this.root.querySelector("#share-card-loading")
    this.shareButton = this.root.querySelector("#share-recap-share")
    this.downloadButton = this.root.querySelector("#share-recap-download")
    this.abortController = new AbortController()
    this.previousBodyOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"

    const options = {signal: this.abortController.signal}
    this.periodButtons.forEach(button => button.addEventListener("click", () => this.loadPeriod(button.dataset.sharePeriod), options))
    this.shareButton.addEventListener("click", () => this.shareImage(), options)
    this.downloadButton.addEventListener("click", () => this.downloadImage(), options)
    this.loadPeriod(this.el.dataset.defaultPeriod || "year")
  },

  destroyed() {
    this.abortController?.abort()
    document.body.style.overflow = this.previousBodyOverflow || ""
  },

  async loadPeriod(period) {
    this.requestId = (this.requestId || 0) + 1
    const requestId = this.requestId
    const now = new Date()
    const bounds = periodBounds(period, now)
    this.period = period
    this.bounds = bounds
    this.now = now
    this.currentBlob = null
    this.currentFile = null
    this.setLoading(true, `Building ${period === "all" ? "your all-time" : `this ${period}`} recap…`)
    this.periodButtons.forEach(button => button.setAttribute("aria-pressed", String(button.dataset.sharePeriod === period)))

    const payload = {period}
    if(bounds.from && bounds.until) {
      payload.from = bounds.from.toISOString()
      payload.until = bounds.until.toISOString()
    }

    this.pushEvent("share_summary", payload, async reply => {
      if(requestId !== this.requestId) return
      if(!reply.ok) {
        this.setLoading(false, reply.error || "Could not build this recap.")
        return
      }

      await document.fonts?.ready
      renderRecap(this.el, reply.summary, period, bounds, now)
      this.el.dataset.period = period
      this.el.dataset.trackCount = String(reply.summary.track_count)
      this.filename = periodFilename(period, bounds, now)
      this.el.dataset.filename = this.filename

      if(reply.summary.track_count === 0) {
        this.setLoading(false, "No analyzed tracks fall inside this period.", false)
        return
      }

      try {
        this.currentBlob = await canvasBlob(this.el)
        this.currentFile = new File([this.currentBlob], this.filename, {type: "image/png"})
        this.shareSupported = Boolean(navigator.share && navigator.canShare?.({files: [this.currentFile]}))
        this.shareButton.classList.toggle("hidden", !this.shareSupported)
        this.shareButton.classList.toggle("inline-flex", this.shareSupported)
        this.setLoading(false, `${periodLabel(period, bounds, now)} is ready.`, true)
        this.el.dataset.ready = "true"
      } catch(error) {
        this.setLoading(false, error.message || "Could not create the PNG.")
      }
    })
  },

  setLoading(loading, message, ready = false) {
    this.loading.classList.toggle("hidden", !loading)
    this.status.textContent = message
    this.downloadButton.disabled = !ready
    this.shareButton.disabled = !ready
    if(!ready) this.el.dataset.ready = "false"
  },

  downloadImage() {
    if(!this.currentBlob) return
    const url = URL.createObjectURL(this.currentBlob)
    const link = document.createElement("a")
    link.href = url
    link.download = this.filename
    link.click()
    setTimeout(() => URL.revokeObjectURL(url), 1_000)
    this.status.textContent = `${this.filename} downloaded.`
  },

  async shareImage() {
    if(!this.currentFile || !this.shareSupported) return
    try {
      await navigator.share({files: [this.currentFile], title: "Track / Atlas recap"})
      this.status.textContent = "Recap shared."
    } catch(error) {
      if(error.name === "AbortError") this.status.textContent = "Sharing canceled."
      else this.status.textContent = "Could not open the share sheet. Download the PNG instead."
    }
  },
}
