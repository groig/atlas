# Understanding heart-rate analysis

Track / Atlas reads HR from GPX point extensions inside OsmAnd OSF exports, including Garmin `TrackPointExtension/hr` and OsmAnd `hr` elements. Original extension values are retained alongside normalized BPM readings. No external health service is contacted, and HR is excluded from share recaps.

## Observations and gaps

- Readings between 30 and 240 BPM are usable numeric observations, not guarantees of sensor accuracy. Missing, malformed, zero, and out-of-range values are unavailable.
- Averages are time weighted, using linear interpolation only between consecutive readings in the same segment, at most 30 seconds apart. Missing readings, repeated/backward timestamps, and recording gaps are not bridged.
- HR is independent of GPS spike rejection. Moving averages additionally require valid movement data. Time coverage is covered HR seconds divided by elapsed track time; sample counts alone can hide recording gaps.
- Changes exceeding 30 BPM within 10 seconds are flagged for inspection. They remain in the recorded profile and descriptive summaries, but affected intervals cannot support route comparisons or drift analysis. A flag does not prove the sensor was wrong.
- Summary calculations use full-resolution observations. The browser uses compact, aligned chart/map samples and explicitly breaks the HR line when a skipped interval contains a gap.

The distribution shows time in absolute 10 BPM bands. The cumulative curve shows time at or above each BPM. Neither is a personalized physiological zone model.

Sustained HR means the highest continuous time-weighted average over 1, 5, 10, or 20 minutes. The source interval is selectable. These are descriptive observations, not awards or suggestions to push HR higher.

## Comparing repeated routes

Route matching checks activity, geometry, endpoints, and direction; loops are aligned to the same route positions. Opposite directions are kept separate. HR comparisons use equal-distance sectors with at least 90% usable HR, excluding the first five minutes and the first minute after a stop. An attempt also needs at least 90% overall HR time coverage. Both attempts must contribute at least three minutes across shared eligible sectors.

The displayed values are medians of the shared sectors, not whole-ride averages. The links open the time span containing those sectors so you can inspect the surrounding context; excluded portions in that span are not part of the comparison.

- **Similar speed:** within 5%. Compare HR differences, with a minimum 5 BPM noise floor.
- **Similar HR:** within 5 BPM. Compare speed differences, with a minimum 2% noise floor.
- **Different effort:** both speed and HR differ beyond those tolerances. This is not treated as fitness improvement.

Longer-term signals require six eligible attempts over at least 14 days. The latest three are compared with the preceding three on the same shared sectors. The noise floor increases when the groups have more variation, using twice their larger median absolute deviation. A pair can be available before a longer-term signal exists.

These comparisons do not control wind, heat, hydration, fatigue, drafting, traffic, equipment, or sensor placement. Lower HR at similar speed is a recorded observation—not proof of improved fitness.

## HR–speed drift

Drift is available only for a continuous window of at least 30 minutes after warm-up and stop exclusions, with usable HR throughout. Speed's time-weighted coefficient of variation must be at most 15%, and at least 90% of the window must have known grade within ±2%.

The window is split into equal-duration halves. Drift is the percentage decrease in moving speed per BPM from the first half to the second. Positive drift means less speed per BPM later. No universal “good/bad” threshold is applied; outdoor cycling speed is not power, and many ordinary tracks are unsuitable for this calculation.

## Optional bands and recorded load

By default, there are no personalized zones or load scores. Supply a maximum HR you already know, or explicit lower boundaries. Maximum HR is never inferred from age or the highest sample in your library.

The known-maximum method uses boundaries at 60%, 70%, 80%, and 90%; the first band includes all usable readings below 60%. Boundaries are rounded to integer BPM. Custom boundaries must increase strictly, beginning at 30 BPM to include all usable readings. The top band includes readings above the configured maximum.

Recorded load is the sum of minutes in each band multiplied by its band number, 1–5. Historical 7/28-day totals use the current profile and only recorded HR portions. Empty windows remain unavailable, not zero training. This simple transparent metric is not TSS, Strava Relative Effort, TRIMP, a fitness score, or a recovery prescription.

Settings changes queue background recalibration of stored summaries. Profile revisions and database locking prevent an older analysis or calibration job from overwriting newer settings. There is no need to re-upload tracks when changing bands.

## Updating existing tracks

New imports include HR automatically. For an existing library, run database migrations and use **Update analyses** in the Heart rate view (or `mix track_analyzer.reanalyze --stale`). The original private files must still exist. No GPX file can supply HR that was not recorded.
