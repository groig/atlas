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

// Monthly bars whenever they fit (a year, or an all-time span of up to two
// years); days for a week or a month; years only for long histories.
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
  } else if(rows.length > 0) {
    const times = rows.map(row => row.date.getTime())
    const first = new Date(Math.min(...times))
    const last = new Date(Math.max(...times))
    const months = (last.getFullYear() - first.getFullYear()) * 12 + last.getMonth() - first.getMonth() + 1

    if(months <= 24) {
      keyFor = monthKey
      buckets = Array.from({length: months}, (_, index) => {
        const date = new Date(first.getFullYear(), first.getMonth() + index, 1)
        return {key: monthKey(date), label: date.toLocaleDateString(undefined, {month: months > 12 ? "narrow" : "short"}), showLabel: true}
      })
    } else {
      keyFor = date => String(date.getFullYear())
      buckets = Array.from({length: last.getFullYear() - first.getFullYear() + 1}, (_, index) => {
        const year = String(first.getFullYear() + index)
        return {key: year, label: year, showLabel: true}
      })
    }
  }

  const totals = rows.reduce((result, row) => {
    const key = keyFor(row.date)
    result[key] = (result[key] || 0) + Number(row.distance_m || 0)
    return result
  }, {})

  return buckets.map(bucket => ({...bucket, distanceM: totals[bucket.key] || 0}))
}

// Values are drawn as runs of [text, unit?]: numbers large, units smaller and muted.
const NONE = [["—"]]
const finite = value => value !== null && value !== undefined && Number.isFinite(Number(value))
const grouped = (value, digits = 0) => Number(value).toLocaleString("en-US", {minimumFractionDigits: digits, maximumFractionDigits: digits})

const distanceParts = meters => {
  if(!finite(meters)) return NONE
  const km = meters / 1_000
  if(km >= 99.95) return [[grouped(km)], [" km", true]]
  if(km >= 1) return [[km.toFixed(1)], [" km", true]]
  return [[String(Math.round(meters))], [" m", true]]
}

const elevationParts = meters => finite(meters) ? [[grouped(meters)], [" m", true]] : NONE
const countParts = value => finite(value) ? [[grouped(value)]] : NONE

const durationParts = seconds => {
  if(!finite(seconds)) return NONE
  const totalMinutes = Math.max(Math.round(seconds / 60), 0)
  const hours = Math.floor(totalMinutes / 60)
  const minutes = totalMinutes % 60
  if(hours === 0) return [[String(minutes)], [" min", true]]
  // Past ten hours, minutes are noise on a story card.
  if(hours >= 10) return [[grouped(Math.round(totalMinutes / 60))], [" h", true]]
  return [[grouped(hours)], ["h ", true], [String(minutes).padStart(2, "0")], ["m", true]]
}

const plain = parts => parts.map(([text]) => text).join("")

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

const label = (context, text, x, y, color = palette.muted, size = 28) => {
  font(context, 700, size)
  context.fillStyle = color
  if("letterSpacing" in context) context.letterSpacing = `${Math.round(size * 0.12)}px`
  context.fillText(text.toUpperCase(), x, y)
  if("letterSpacing" in context) context.letterSpacing = "0px"
}

const UNIT_SCALE = 0.42

const measureParts = (context, parts, size) => parts.reduce((width, [text, unit]) => {
  font(context, unit ? 700 : 900, unit ? Math.round(size * UNIT_SCALE) : size)
  return width + context.measureText(text).width
}, 0)

const fittedSize = (context, parts, size, maximumWidth) => {
  let fitted = size
  while(fitted > 32 && measureParts(context, parts, fitted) > maximumWidth) fitted -= 2
  return fitted
}

// Draws a value on one baseline, shrinking it until it fits the given width.
const drawValue = (context, parts, x, y, size, maximumWidth, color = palette.ink) => {
  const fitted = fittedSize(context, parts, size, maximumWidth)

  let cursor = x
  parts.forEach(([text, unit]) => {
    font(context, unit ? 700 : 900, unit ? Math.round(fitted * UNIT_SCALE) : fitted)
    context.fillStyle = unit ? palette.muted : color
    context.fillText(text, cursor, y)
    cursor += context.measureText(text).width
  })
  return fitted
}

const MARGIN = 88
const CONTENT = WIDTH - MARGIN * 2

const drawBrand = context => {
  fillRoundRect(context, MARGIN, 92, 56, 56, 16, palette.accent)
  context.strokeStyle = palette.accentInk
  context.lineWidth = 4
  context.lineJoin = "round"
  context.beginPath()
  context.moveTo(MARGIN + 16, 112)
  context.lineTo(MARGIN + 26, 107)
  context.lineTo(MARGIN + 39, 113)
  context.lineTo(MARGIN + 39, 133)
  context.lineTo(MARGIN + 27, 127)
  context.lineTo(MARGIN + 16, 133)
  context.closePath()
  context.stroke()

  font(context, 800, 32)
  context.fillStyle = palette.ink
  context.fillText("Track / Atlas", MARGIN + 78, 131)
}

const drawBackground = context => {
  context.fillStyle = palette.canvas
  context.fillRect(0, 0, WIDTH, HEIGHT)

  const glow = context.createRadialGradient(860, 360, 0, 860, 360, 760)
  glow.addColorStop(0, "rgba(216, 255, 69, 0.13)")
  glow.addColorStop(1, "rgba(216, 255, 69, 0)")
  context.fillStyle = glow
  context.fillRect(0, 0, WIDTH, 1100)

  // Faint contour lines, a nod to the map without showing any route.
  context.strokeStyle = "rgba(54, 227, 205, 0.07)"
  context.lineWidth = 2
  for(let index = 0; index < 5; index += 1) {
    context.beginPath()
    context.ellipse(930, 380, 170 + index * 70, 260 + index * 80, -0.35, 0, Math.PI * 2)
    context.stroke()
  }
}

const drawStat = (context, title, parts, x, y, width, size = 92) => {
  label(context, title, x, y, palette.muted, 26)
  drawValue(context, parts, x, y + size + 18, size, width)
}

const drawRhythm = (context, rhythm, top, height) => {
  const plotX = MARGIN
  const plotWidth = CONTENT
  const labelSpace = 54
  const valueSpace = 64
  const plotY = top + valueSpace
  const plotHeight = height - labelSpace - valueSpace
  if(rhythm.length === 0) return

  const maximum = Math.max(...rhythm.map(bucket => bucket.distanceM), 1)
  const best = rhythm.reduce((winner, bucket, index) => bucket.distanceM > rhythm[winner].distanceM ? index : winner, 0)
  const gap = rhythm.length > 16 ? 6 : 14
  const barWidth = Math.max((plotWidth - gap * (rhythm.length - 1)) / rhythm.length, 4)

  rhythm.forEach((bucket, index) => {
    const isBest = index === best && bucket.distanceM > 0
    const barHeight = bucket.distanceM > 0 ? Math.max(bucket.distanceM / maximum * plotHeight, 10) : 4
    const barX = plotX + index * (barWidth + gap)
    const fill = isBest ? palette.accent : bucket.distanceM > 0 ? "rgba(54, 227, 205, 0.45)" : "rgba(147, 165, 154, 0.16)"
    fillRoundRect(context, barX, plotY + plotHeight - barHeight, barWidth, barHeight, Math.min(10, barWidth / 2), fill)

    if(isBest) {
      const text = plain(distanceParts(bucket.distanceM))
      font(context, 800, 30)
      context.fillStyle = palette.accent
      const textWidth = context.measureText(text).width
      const centered = barX + barWidth / 2 - textWidth / 2
      context.fillText(text, Math.min(Math.max(centered, plotX), plotX + plotWidth - textWidth), plotY + plotHeight - barHeight - 20)
    }

    if(bucket.showLabel) {
      font(context, isBest ? 800 : 600, rhythm.length > 16 ? 20 : 24)
      context.fillStyle = isBest ? palette.ink : palette.muted
      context.textAlign = "center"
      context.fillText(bucket.label, barX + barWidth / 2, plotY + plotHeight + 42)
      context.textAlign = "left"
    }
  })
}

const drawEmpty = context => {
  label(context, "Distance", MARGIN, 330)
  drawValue(context, [["0"], [" km", true]], MARGIN, 600, 260, CONTENT)
  font(context, 600, 40)
  context.fillStyle = palette.muted
  context.fillText("No rides in this period yet.", MARGIN, 720)
}

const renderRecap = (canvas, summary, period, bounds, now = new Date()) => {
  const context = canvas.getContext("2d")
  canvas.width = WIDTH
  canvas.height = HEIGHT
  drawBackground(context)
  drawBrand(context)

  const periodText = periodLabel(period, bounds, now)
  context.textAlign = "right"
  label(context, periodText, WIDTH - MARGIN, 131, palette.muted, period === "week" ? 20 : 24)
  context.textAlign = "left"

  if(summary.track_count === 0) {
    drawEmpty(context)
  } else {
    const activity = summary.activity || []

    // Hero: the one number that matters most.
    label(context, "Distance", MARGIN, 340, palette.accent, 28)
    drawValue(context, distanceParts(summary.distance_m), MARGIN, 600, 250, CONTENT)

    const stats = [
      ["Moving time", durationParts(summary.moving_s)],
      ["Elevation", elevationParts(summary.elevation_gain_m)],
      ["Rides", countParts(summary.track_count)],
    ]
    // One shared size, so the row reads as a set rather than three sizes.
    const column = CONTENT / stats.length
    const size = Math.min(...stats.map(([, parts]) => fittedSize(context, parts, 92, column - 36)))
    stats.forEach(([title, parts], index) => {
      drawStat(context, title, parts, MARGIN + index * column, 812, column - 36, size)
    })

    // Header, hero, stats and chart sit about 175 px apart, bottom margin included.
    drawRhythm(context, recapRhythm(period, activity, bounds), 1076, 680)
  }

  canvas.setAttribute("aria-label", `${periodText}. ${summary.track_count} rides, ${plain(distanceParts(summary.distance_m))}.`)
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
