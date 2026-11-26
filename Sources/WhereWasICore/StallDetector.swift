import Foundation

/// Energy-based voice activity detection + stall detection.
/// Pure Swift (no AVFoundation / UIKit) so it can be unit-tested on Linux.
///
/// Logic and thresholds are a direct port of the Android `StallDetector`
/// in `/workspace/where-was-i/src/main/java/com/iqbal/wherewasi/StallDetector.java`.
/// Feed it consecutive frames of 16 kHz mono PCM (`Int16`).
public final class StallDetector: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case listening
        case speaking
        case paused
    }

    public struct SampleRange: Equatable, Sendable {
        public var start: Int64
        public var end: Int64
        public var count: Int64 { end - start }

        public init(start: Int64, end: Int64) {
            self.start = start
            self.end = end
        }
    }

    public let sampleRate: Int

    // Tunables — keep in lockstep with the Android prototype.
    public var onsetMarginDb = 9.0     // smoothed level must exceed noise floor by this to start speech
    public var releaseMarginDb = 5.0   // ...and drop below floor+this to count as silence (hysteresis)
    public var minAbsDb = -55.0        // never treat anything quieter than this as speech
    public var onsetMs = 60.0          // sustained loudness needed to declare speech
    public var joinGapMs = 800.0       // gaps shorter than this join segments into one utterance
    public var minUtteranceMs = 300.0  // ignore clicks/bumps shorter than this
    public var stallMs = 3000.0        // silence after speech that triggers replay
    public var maxReplayMs = 10000.0   // cap replay to the last N ms of speech
    public var prePadMs = 150.0
    public var postPadMs = 250.0

    /// Called once when silence after speech reaches the stall time.
    /// `[start, end)` are absolute sample indexes into the ring buffer.
    public var onStall: ((Int64, Int64) -> Void)?

    private var pos: Int64 = 0                 // absolute sample index of next frame
    private var noiseFloorDbValue: Double = -60
    private var smoothDb: Double = -90
    private var inSegment = false              // currently above threshold (after onset)
    private var aboveSince: Int64 = -1
    private var belowSince: Int64 = -1
    private var uttStart: Int64 = -1
    private var uttEnd: Int64 = -1             // current utterance (joined segments)
    private var stallFired = true              // nothing to fire until speech is heard
    private var lastLevelDbValue: Double = -90
    private var calibrated = false
    private var framesSeen: Int64 = 0
    private var calibrationFrames = 0

    /// Starts of the speech segments that make up the current (joined) utterance.
    /// Used to start a capped replay at a phrase boundary instead of mid-word.
    private var segmentStarts: [Int64] = []

    /// Minimum-statistics window of recent frame levels (dB). Its minimum is a
    /// noise estimate that keeps working while speech is in progress, so a steady
    /// noise that starts mid-session (fan, air conditioner, TV hum) cannot hold the
    /// detector in "speaking" forever.
    public var noiseWindowMs = 2500.0
    private var levelWindow: [Double] = []
    private var levelWindowIndex = 0

    public init(sampleRate: Int) {
        self.sampleRate = sampleRate
    }

    public func setStallSeconds(_ s: Double) {
        stallMs = s * 1000.0
    }

    /// Convert a duration in milliseconds to a sample count (truncated, matching Java).
    public func samples(forMs m: Double) -> Int64 {
        Int64(m * Double(sampleRate) / 1000.0)
    }

    public var levelDb: Double { lastLevelDbValue }
    public var noiseFloorDb: Double { noiseFloorDbValue }
    public var position: Int64 { pos }

    public var state: State {
        if inSegment { return .speaking }
        if uttStart >= 0 && !stallFired { return .paused }
        return .listening
    }

    /// Forget the current utterance and timing (e.g. after replay/resume). Noise floor is kept.
    public func resetUtterance(newPos: Int64) {
        pos = newPos
        inSegment = false
        aboveSince = -1
        belowSince = -1
        uttStart = -1
        uttEnd = -1
        segmentStarts.removeAll()
        stallFired = true
    }

    /// Keep the most recent utterance available for a manual replay, but do not
    /// auto-replay it. Use when listening resumes after a gap that the sample
    /// clock did not see (app was in the background, a phone call, Siri).
    public func cancelPendingStall() {
        if inSegment {
            inSegment = false
            uttEnd = pos
        }
        aboveSince = -1
        belowSince = -1
        stallFired = true
    }

    /// The current/most recent utterance range, capped to maxReplay, or nil.
    public func lastUtterance() -> SampleRange? {
        guard uttStart >= 0 else { return nil }
        let end = inSegment ? pos : uttEnd
        return clampRange(start: uttStart, end: end)
    }

    private func clampRange(start: Int64, end: Int64) -> SampleRange {
        var s = max(Int64(0), start - samples(forMs: prePadMs))
        let e = min(pos, end + samples(forMs: postPadMs))
        let cap = samples(forMs: maxReplayMs)
        if e - s > cap {
            let earliest = e - cap
            // Prefer the first phrase that fits entirely inside the cap.
            let pre = samples(forMs: prePadMs)
            if let seg = segmentStarts.first(where: { $0 - pre >= earliest && $0 < end }),
               e - (seg - pre) >= samples(forMs: minUtteranceMs) {
                s = seg - pre
            } else {
                s = earliest
            }
        }
        return SampleRange(start: s, end: e)
    }

    public func process(_ frame: [Int16]) {
        process(frame, length: frame.count)
    }

    public func process(_ frame: [Int16], length len: Int) {
        let n = min(max(0, len), frame.count)
        var sum = 0.0
        if n > 0 {
            for i in 0..<n {
                let v = Double(frame[i]) / 32768.0
                sum += v * v
            }
        }
        let rms = (sum / Double(max(1, n))).squareRoot()
        let db = 20 * Foundation.log10(rms + 1e-9)
        lastLevelDbValue = db
        let frameStart = pos
        pos += Int64(n)
        framesSeen += 1

        // Smoothing: fast attack, slower release
        let a = db > smoothDb ? 0.5 : 0.15
        smoothDb = smoothDb + a * (db - smoothDb)

        // Exact digital silence (all-zero frames) is what iOS often delivers for the
        // first buffers after the engine starts or a route changes. It says nothing
        // about the room, so it must not calibrate or pull down the noise floor.
        let digitalSilence = sum == 0

        // Adaptive noise floor: drops quickly to quiet levels, rises slowly.
        if !digitalSilence {
            if !calibrated {
                noiseFloorDbValue = calibrationFrames == 0 ? db : min(noiseFloorDbValue, db)
                calibrationFrames += 1
                if calibrationFrames >= 10 {
                    calibrated = true
                    noiseFloorDbValue = max(noiseFloorDbValue, -75)
                }
            } else if db < noiseFloorDbValue {
                noiseFloorDbValue += 0.3 * (db - noiseFloorDbValue)
            } else if !inSegment {
                noiseFloorDbValue += 0.004 * (db - noiseFloorDbValue) // creeps up over several seconds
            }
        }

        // Minimum statistics: speech always dips between words within a couple of
        // seconds; steady noise does not. Let the floor rise toward the recent
        // minimum even during a segment. Digital silence enters the window as a very
        // low level, so it can only hold the floor down, never push it up.
        let windowFrames = min(500, max(1, Int(noiseWindowMs * Double(sampleRate) / 1000.0) / max(1, n)))
        let windowDb = digitalSilence ? -120.0 : db
        if levelWindow.count < windowFrames {
            levelWindow.append(windowDb)
        } else {
            levelWindow[levelWindowIndex % levelWindow.count] = windowDb
            levelWindowIndex += 1
        }
        if calibrated, levelWindow.count >= windowFrames, let windowMin = levelWindow.min(),
           windowMin > noiseFloorDbValue {
            noiseFloorDbValue += 0.03 * (windowMin - noiseFloorDbValue)
        }
        noiseFloorDbValue = max(-80, min(-25, noiseFloorDbValue))

        let onThr = max(noiseFloorDbValue + onsetMarginDb, minAbsDb)
        let offThr = max(noiseFloorDbValue + releaseMarginDb, minAbsDb - 3)

        if !inSegment {
            if smoothDb > onThr {
                if aboveSince < 0 { aboveSince = frameStart }
                if pos - aboveSince >= samples(forMs: onsetMs) {
                    inSegment = true
                    belowSince = -1
                    let join = uttStart >= 0 && !stallFired && (aboveSince - uttEnd) < samples(forMs: joinGapMs)
                    if !join {
                        uttStart = aboveSince
                        segmentStarts.removeAll()
                    }
                    segmentStarts.append(aboveSince)
                    if segmentStarts.count > 256 {
                        segmentStarts.removeFirst(segmentStarts.count - 256)
                    }
                    stallFired = false
                }
            } else {
                aboveSince = -1
            }
        } else {
            if smoothDb < offThr {
                if belowSince < 0 { belowSince = frameStart }
                if pos - belowSince >= samples(forMs: 120) { // short hangover before declaring segment end
                    inSegment = false
                    aboveSince = -1
                    uttEnd = belowSince
                }
            } else {
                belowSince = -1
            }
        }

        if !inSegment && uttStart >= 0 && !stallFired {
            if uttEnd - uttStart < samples(forMs: minUtteranceMs) && pos - uttEnd >= samples(forMs: joinGapMs) {
                // too short to be speech (cough/click): drop it
                uttStart = -1
                uttEnd = -1
                segmentStarts.removeAll()
                stallFired = true
            } else if pos - uttEnd >= samples(forMs: stallMs) {
                stallFired = true
                let r = clampRange(start: uttStart, end: uttEnd)
                onStall?(r.start, r.end)
            }
        }
    }
}
