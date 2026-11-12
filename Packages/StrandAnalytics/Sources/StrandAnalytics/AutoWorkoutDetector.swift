import Foundation
import WhoopProtocol

// AutoWorkoutDetector.swift — opt-in MVP "did you just work out?" detector.
//
// Faithful Swift twin of android/.../com/noop/analytics/AutoWorkoutDetector.kt — the two MUST
// stay BYTE-PARITY on the detection logic (same thresholds, same span/merge/overlap rules, same
// outputs), verified by the mirrored unit tests on each platform.
//
// This is DELIBERATELY SEPARATE from `WorkoutDetector` (the exercise.py port that computes
// calories / zones / strain for daily analytics and enriches already logged workouts). This one
// is the lightweight, OPT-IN, NON-DESTRUCTIVE confirmation detector that only ever SUGGESTS a
// workout via a dismissible Today card — it never writes a row on its own. The user taps "Save"
// to turn a suggestion into a manual workout, or X to dismiss it forever. Its published policy
// remains frozen while the duration alternatives collect local shadow evidence.
//
// The published thresholds here are intentionally CONSERVATIVE (low sensitivity): a sustained ≥ 12-min
// elevation of HR ≥ resting + 30 bpm, brief (≤ 90 s) dips tolerated, near windows merged. Tuned
// to avoid false positives from stress / caffeine / a brief flight of stairs, at the cost of
// missing the odd short or gentle session — exactly right for a SUGGESTION you can decline. An
// OPTIONAL continuous motion signal, when one is readily available, is required as confirmation;
// with no motion series it runs HR-only.
//
// The 10- and 15-minute alternatives are SHADOW policies only. Test Centre may run them beside the
// published 12-minute result to compare against labelled workouts, but they must not drive the Today
// card, persistence, classification, or downstream scores until real-world validation supports a change.
//
// Pure / headless: no I/O, no clock. All ts/start/end are unix SECONDS. NOT medical advice.

/// A candidate workout window the user can accept (Save) or reject (dismiss). All fields are
/// derived purely from the HR samples inside the window. Mirrors the Kotlin `DetectedWorkout`.
public struct DetectedWorkout: Equatable, Sendable {
    public let startSec: Int
    public let endSec: Int
    public let avgBpm: Int
    public let peakBpm: Int
    /// Whole minutes, floor of (endSec - startSec) / 60 — what the prompt shows.
    public let durationMin: Int

    public init(startSec: Int, endSec: Int, avgBpm: Int, peakBpm: Int, durationMin: Int) {
        self.startSec = startSec
        self.endSec = endSec
        self.avgBpm = avgBpm
        self.peakBpm = peakBpm
        self.durationMin = durationMin
    }
}

/// A [startSec, endSec] span of an already-saved workout, used to exclude windows that overlap a
/// session the user has already logged (so we never re-suggest one). Mirrors the Kotlin
/// `Pair<Long, Long>` saved-workout argument.
public struct SavedWorkoutSpan: Equatable, Sendable {
    public let startSec: Int
    public let endSec: Int
    public init(startSec: Int, endSec: Int) {
        self.startSec = startSec
        self.endSec = endSec
    }
}

public enum AutoWorkoutDetector {

    // MARK: - Constants (keep byte-identical with the Kotlin twin)

    /// Elevated gate: bpm must be at least restingHR + this margin to count as "working".
    public static let elevatedMarginBPM = 30
    /// A candidate must hold the elevated gate for a contiguous span of at least this long (12 min).
    public static let minSustainedMin: Double = 12.0
    /// Candidate duration policies evaluated only by local Test Centre shadow diagnostics.
    /// The published confirmation path continues to use `minSustainedMin` (12 minutes).
    public static let shadowSustainedMinutes: [Double] = [10.0, 15.0]
    /// A dip below the gate no longer than this does NOT break the span (a red light, a sip of water).
    public static let maxDipS = 90
    /// Two detected windows whose gap is strictly less than this are merged into one (5 min).
    public static let mergeGapS = 5 * 60
    /// When an OPTIONAL continuous motion series is supplied, a window must ALSO show elevated motion
    /// to qualify (confirmation). "Elevated motion" = the window's mean per-second motion intensity
    /// (L2 gravity-delta) is at least this. Ignored entirely in HR-only mode. Matches the Kotlin twin.
    public static let motionConfirmMean = 0.05
    /// Resting-HR fallback when the caller has no nightly RHR for the day.
    public static let defaultRestingHR = 60

    // Fork change: the nightly RHR sits far below waking HR (RHR 49 vs a waking median of ~71–78),
    // so restingHR + 30 is cleared by walking, eating or sitting, and windows bled hours past the
    // real session. When the series is long enough to know the waking level, the gate is raised to
    // that level + `awakeMarginBPM`; short series (tests, a fresh install) keep restingHR + 30.

    /// Gate above the waking median HR when a waking baseline is available.
    public static let awakeMarginBPM = 20
    /// A sample counts toward the waking baseline when bpm >= restingHR + this (drops sleep).
    public static let awakeSampleMarginBPM = 10
    /// The waking baseline is only trusted over at least this much wall-clock HR (6 h).
    public static let awakeBaselineMinSpanS = 6 * 3600
    /// ...and at least this many waking samples.
    public static let awakeBaselineMinSamples = 600

    /// Tail trim: a window that had an intense phase (5-min median >= floor + this) and then runs on
    /// for more than `tailTrimMinS` below it ends `tailKeepS` after the last intense minute. Cuts the
    /// raised-but-idle evening that otherwise follows a hard session.
    public static let intenseMarginBPM = 30
    public static let tailTrimMinS = 20 * 60
    public static let tailKeepS = 5 * 60
    static let tailWindowS = 5 * 60

    // MARK: - Inputs

    /// One motion-intensity reading aligned to the HR timeline (optional confirmation signal).
    /// `intensity` is on the same L2-gravity-delta scale as `WorkoutDetector.activitySeries`.
    /// (The Kotlin twin takes raw `GravitySample`s and derives this internally; the Swift call site
    /// — `Repository.autoDetectCandidate` — has the gravity already decoded, so it passes the points.)
    public struct MotionPoint: Equatable, Sendable {
        public let ts: Int
        public let intensity: Double
        public init(ts: Int, intensity: Double) {
            self.ts = ts
            self.intensity = intensity
        }
    }

    /// Per-second motion intensity = L2 magnitude of the gravity change vs the previous record.
    /// First row → 0. Empty input → []. Mirrors the Kotlin `motionIntensityByTs` (and
    /// `WorkoutDetector.activitySeries`) so a caller can build the optional `motion` argument.
    public static func motionPoints(_ gravity: [GravitySample]) -> [MotionPoint] {
        if gravity.isEmpty { return [] }
        let rows = gravity.sorted { $0.ts < $1.ts }
        var out: [MotionPoint] = []
        out.reserveCapacity(rows.count)
        var prev: GravitySample? = nil
        for (i, row) in rows.enumerated() {
            let intensity: Double
            if i == 0, prev == nil {
                intensity = 0.0
            } else if let p = prev {
                let dx = row.x - p.x, dy = row.y - p.y, dz = row.z - p.z
                intensity = (dx * dx + dy * dy + dz * dz).squareRoot()
            } else {
                intensity = 0.0
            }
            out.append(MotionPoint(ts: row.ts, intensity: intensity))
            prev = row
        }
        return out
    }

    // MARK: - Public API

    /// Detect candidate sustained-elevated-HR workout windows.
    ///
    /// Algorithm (kept byte-identical with the Kotlin twin):
    ///  1. Sort HR ascending. Floor = restingHR + `elevatedMarginBPM`. A sample is "elevated" when
    ///     bpm >= floor.
    ///  2. Grow a contiguous span across elevated samples. A run of NON-elevated samples is tolerated
    ///     (does not end the span) ONLY while the dip's wall-clock duration (from the first sub-threshold
    ///     sample) stays <= `maxDipS`; a longer dip closes the span. The span's [start, end] are the
    ///     first/last ELEVATED sample timestamps.
    ///  3. Keep a span only when it lasts >= `minimumSustainedMinutes` (applied per-span, BEFORE merge).
    ///  4. Merge two kept spans when the gap between them is strictly < `mergeGapS`.
    ///  5. If a motion series is supplied, drop a window unless its mean motion intensity over the
    ///     window is >= `motionConfirmMean` (confirmation). With no motion series, HR-only — keep it.
    ///  6. Drop a window that OVERLAPS any saved span (touching endpoints count) — never re-suggest one.
    ///  7. Emit a `DetectedWorkout` per surviving window (avg/peak bpm + whole-minute duration).
    ///
    /// - Parameters:
    ///   - hr: the day's (or last day or two's) HR samples `[(ts, bpm)]`; any order; empty → [].
    ///   - restingBpm: the nightly resting HR for the day; nil → `defaultRestingHR` (60).
    ///   - motion: OPTIONAL continuous motion series for confirmation; nil/empty → HR-only.
    ///   - savedSpans: already-saved workout windows to exclude by overlap.
    ///   - minimumSustainedMinutes: duration policy. The default is the published 12-minute policy;
    ///     callers may pass values from `shadowSustainedMinutes` only for local shadow diagnostics.
    public static func detect(hr: [(ts: Int, bpm: Int)],
                              restingBpm: Int?,
                              motion: [MotionPoint]? = nil,
                              savedSpans: [SavedWorkoutSpan] = [],
                              minimumSustainedMinutes: Double = minSustainedMin) -> [DetectedWorkout] {
        let seg = hr.sorted { $0.ts < $1.ts }
        if seg.isEmpty { return [] }

        let floor = elevatedFloor(sorted: seg, restingBpm: restingBpm)

        // --- 1 + 2 + 3: grow sustained spans tolerating brief dips ---
        // A span is [spanStart, spanEnd] over ELEVATED-sample timestamps. `dipStart` marks where the
        // current sub-threshold run began (nil = not in a dip); a dip longer than maxDipS closes the span.
        var spans: [(start: Int, end: Int)] = []
        var spanStart: Int? = nil
        var spanEnd = 0
        var dipStart: Int? = nil

        func closeSpan() {
            if let s = spanStart, Double(spanEnd - s) >= minimumSustainedMinutes * 60.0 {
                spans.append((s, spanEnd))
            }
            spanStart = nil
            dipStart = nil
        }

        for sample in seg {
            if sample.bpm >= floor {
                if spanStart == nil { spanStart = sample.ts }
                spanEnd = sample.ts
                dipStart = nil   // the dip (if any) is bridged
            } else if spanStart != nil {
                // In a span: tolerate the dip until it runs longer than maxDipS. `dipStart` is the
                // first sub-threshold sample of the current dip (set once, cleared on the next elevated).
                if dipStart == nil { dipStart = sample.ts }
                if let d = dipStart, sample.ts - d > maxDipS { closeSpan() }
            }
        }
        closeSpan()

        if spans.isEmpty { return [] }

        // --- 4: merge spans whose gap is strictly < mergeGapS (spans are start-ascending by build) ---
        var merged: [(start: Int, end: Int)] = []
        var curStart = spans[0].start
        var curEnd = spans[0].end
        for k in 1..<spans.count {
            let next = spans[k]
            if next.start - curEnd < mergeGapS {
                curEnd = max(curEnd, next.end)
            } else {
                merged.append((curStart, curEnd))
                curStart = next.start
                curEnd = next.end
            }
        }
        merged.append((curStart, curEnd))

        // --- 5 + 6 + 7 ---
        let motionSeries = (motion?.isEmpty ?? true) ? nil : motion
        var results: [DetectedWorkout] = []
        for (start, untrimmedEnd) in merged {
            let end = trimmedEnd(start: start, end: untrimmedEnd, sorted: seg, floor: floor)
            // 6: never re-suggest a window overlapping an already-saved workout.
            if savedSpans.contains(where: { overlaps(start, end, $0.startSec, $0.endSec) }) { continue }

            let window = seg.filter { $0.ts >= start && $0.ts <= end }
            if window.isEmpty { continue }

            // 5: motion confirmation, only when a continuous motion series was supplied.
            if let motionSeries = motionSeries {
                let inWin = motionSeries.filter { $0.ts >= start && $0.ts <= end }.map { $0.intensity }
                let meanMotion = inWin.isEmpty ? 0.0 : inWin.reduce(0.0, +) / Double(inWin.count)
                if meanMotion < motionConfirmMean { continue }
            }

            let bpms = window.map { $0.bpm }
            let avg = Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
            let peak = bpms.max() ?? avg
            let durMin = (end - start) / 60
            results.append(DetectedWorkout(startSec: start, endSec: end,
                                           avgBpm: avg, peakBpm: peak, durationMin: durMin))
        }
        return results
    }

    /// The elevated gate: restingHR + `elevatedMarginBPM`, raised to the waking median +
    /// `awakeMarginBPM` when `sorted` (ascending by ts) covers enough waking HR to measure it.
    public static func elevatedFloor(sorted seg: [(ts: Int, bpm: Int)], restingBpm: Int?) -> Int {
        let resting = restingBpm ?? defaultRestingHR
        let base = resting + elevatedMarginBPM
        guard let first = seg.first, let last = seg.last,
              last.ts - first.ts >= awakeBaselineMinSpanS else { return base }
        let awake = seg.map(\.bpm).filter { $0 >= resting + awakeSampleMarginBPM }.sorted()
        guard awake.count >= awakeBaselineMinSamples else { return base }
        return max(base, awake[awake.count / 2] + awakeMarginBPM)
    }

    /// End of a merged window after the tail trim (see `intenseMarginBPM`). Returns `end` unchanged
    /// when the window never had an intense phase or its tail is short.
    static func trimmedEnd(start: Int, end: Int, sorted seg: [(ts: Int, bpm: Int)], floor: Int) -> Int {
        guard end - start > tailTrimMinS else { return end }
        let window = seg.filter { $0.ts >= start && $0.ts <= end }
        var lastIntense: Int? = nil
        var lo = 0
        var t = start
        while t <= end {
            // Samples in (t - tailWindowS, t]; `lo` only moves forward because `t` does.
            while lo < window.count, window[lo].ts <= t - tailWindowS { lo += 1 }
            var hi = lo
            while hi < window.count, window[hi].ts <= t { hi += 1 }
            if hi - lo >= 30 {
                let bpms = window[lo..<hi].map(\.bpm).sorted()
                if bpms[bpms.count / 2] >= floor + intenseMarginBPM { lastIntense = t }
            }
            t += 60
        }
        guard let li = lastIntense, end - li > tailTrimMinS else { return end }
        return li + tailKeepS
    }

    /// Two closed [aStart, aEnd] / [bStart, bEnd] intervals overlap (touching endpoints count).
    /// Mirrors the Kotlin `overlaps`.
    static func overlaps(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Bool {
        aStart <= bEnd && bStart <= aEnd
    }
}
