import XCTest
import Foundation
@testable import WhereWasICore

final class StallDetectorTests: XCTestCase {
    let sampleRate = 16_000
    let frame = 320 // 20 ms

    // MARK: - Helpers

    func silence(_ samples: Int) -> [Int16] {
        [Int16](repeating: 0, count: samples)
    }

    /// A 200 Hz sine at the given full-scale amplitude (0...1).
    func tone(samples: Int, amplitude: Double = 0.2, phase: Double = 0) -> [Int16] {
        let freq = 200.0
        var out = [Int16](repeating: 0, count: samples)
        for i in 0..<samples {
            let s = Foundation.sin(phase + 2.0 * Double.pi * freq * Double(i) / Double(sampleRate))
            let clipped = max(-0.999, min(0.999, s * amplitude))
            out[i] = Int16(clipped * 32767.0)
        }
        return out
    }

    func frames(of samples: Int, builder: (Int) -> [Int16]) -> [[Int16]] {
        var result: [[Int16]] = []
        var remaining = samples
        while remaining > 0 {
            let n = min(frame, remaining)
            result.append(builder(n))
            remaining -= n
        }
        return result
    }

    func feed(_ detector: StallDetector, _ chunks: [[Int16]]) {
        for c in chunks { detector.process(c) }
    }

    func feedSilence(_ detector: StallDetector, ms: Double) {
        let n = Int(ms * Double(sampleRate) / 1000.0)
        feed(detector, frames(of: n) { silence($0) })
    }

    func feedTone(_ detector: StallDetector, ms: Double, amplitude: Double = 0.2) {
        let n = Int(ms * Double(sampleRate) / 1000.0)
        feed(detector, frames(of: n) { tone(samples: $0, amplitude: amplitude) })
    }

    /// Deterministic white noise at roughly `amplitude` peak (rms ≈ amplitude / √3).
    func noise(samples: Int, amplitude: Double, seed: inout UInt64) -> [Int16] {
        var out = [Int16](repeating: 0, count: samples)
        for i in 0..<samples {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let u = Double((seed >> 33) & 0xFFFF) / 65535.0 * 2 - 1
            out[i] = Int16(u * amplitude * 32767.0)
        }
        return out
    }

    func feedNoise(_ detector: StallDetector, ms: Double, amplitude: Double, seed: inout UInt64) {
        let n = Int(ms * Double(sampleRate) / 1000.0)
        var chunks: [[Int16]] = []
        var remaining = n
        while remaining > 0 {
            let c = min(frame, remaining)
            chunks.append(noise(samples: c, amplitude: amplitude, seed: &seed))
            remaining -= c
        }
        feed(detector, chunks)
    }

    /// Speech-like signal: 200 ms "syllables" of tone separated by 60 ms near-silent dips,
    /// so the level dips between words the way real speech does.
    func feedSpeechLike(_ detector: StallDetector, ms: Double, amplitude: Double = 0.2) {
        var t = 0.0
        while t < ms {
            feedTone(detector, ms: min(200, ms - t), amplitude: amplitude)
            t += 200
            if t >= ms { break }
            feedSilence(detector, ms: min(60, ms - t))
            t += 60
        }
    }

    /// Calibrate the adaptive noise floor on a quiet room (first 10 non-zero frames).
    func makeCalibratedDetector() -> StallDetector {
        let d = StallDetector(sampleRate: sampleRate)
        var seed: UInt64 = 42
        feedNoise(d, ms: 250, amplitude: 0.0005, seed: &seed) // ≈ -70 dBFS
        return d
    }

    // MARK: - Tests

    func testSilenceStaysListeningAndDoesNotStall() {
        let d = makeCalibratedDetector()
        var stalled = 0
        d.onStall = { _, _ in stalled += 1 }
        feedSilence(d, ms: 4000)
        XCTAssertEqual(d.state, .listening)
        XCTAssertNil(d.lastUtterance())
        XCTAssertEqual(stalled, 0)
    }

    func testSpeechThenStallFiresOnceWithRange() {
        let d = makeCalibratedDetector()
        var ranges: [StallDetector.SampleRange] = []
        d.onStall = { start, end in ranges.append(.init(start: start, end: end)) }

        XCTAssertEqual(d.state, .listening)
        feedTone(d, ms: 600)
        XCTAssertEqual(d.state, .speaking)
        XCTAssertNotNil(d.lastUtterance())

        // Hangover is 120 ms, then stallMs (default 3000) is measured from uttEnd.
        feedSilence(d, ms: 500)
        XCTAssertEqual(d.state, .paused)
        XCTAssertEqual(ranges.count, 0, "should not stall before the configured silence")

        feedSilence(d, ms: 3200)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(d.state, .listening, "after the stall fires, state returns to listening")

        let r = ranges[0]
        XCTAssertGreaterThan(r.end, r.start)
        let durationMs = Double(r.count) * 1000.0 / Double(sampleRate)
        // 600 ms of tone + 150 pre + 250 post ≈ 1 s, well under the 10 s cap
        XCTAssertGreaterThan(durationMs, 500)
        XCTAssertLessThan(durationMs, 1500)

        // Further silence must not fire again
        feedSilence(d, ms: 4000)
        XCTAssertEqual(ranges.count, 1)
    }

    func testConfigurableStallTime() {
        let d = makeCalibratedDetector()
        d.setStallSeconds(2)
        var stalled = 0
        d.onStall = { _, _ in stalled += 1 }

        feedTone(d, ms: 500)
        feedSilence(d, ms: 1500)
        XCTAssertEqual(stalled, 0, "2 s stall should not fire after 1.5 s of silence")
        feedSilence(d, ms: 1200)
        XCTAssertEqual(stalled, 1)
    }

    func testShortClickIsDroppedAndDoesNotStall() {
        let d = makeCalibratedDetector()
        var stalled = 0
        d.onStall = { _, _ in stalled += 1 }

        // 100 ms is below minUtteranceMs (300)
        feedTone(d, ms: 100)
        feedSilence(d, ms: 1200) // past joinGapMs (800) and hangover
        XCTAssertEqual(stalled, 0)
        XCTAssertNil(d.lastUtterance())
        XCTAssertEqual(d.state, .listening)
    }

    func testShortGapJoinsSegmentsIntoOneUtterance() {
        let d = makeCalibratedDetector()
        var ranges: [StallDetector.SampleRange] = []
        d.onStall = { start, end in ranges.append(.init(start: start, end: end)) }

        feedTone(d, ms: 400)
        feedSilence(d, ms: 400) // shorter than joinGapMs (800)
        feedTone(d, ms: 400)
        feedSilence(d, ms: 3500)

        XCTAssertEqual(ranges.count, 1)
        let durationMs = Double(ranges[0].count) * 1000.0 / Double(sampleRate)
        // Two 400 ms segments plus a 400 ms gap plus pads (~400 ms) ≈ 1.6 s
        XCTAssertGreaterThan(durationMs, 1000)
        XCTAssertLessThan(durationMs, 2500)
    }

    func testLongGapDoesNotJoin() {
        let d = makeCalibratedDetector()
        var starts: [Int64] = []
        d.onStall = { start, _ in starts.append(start) }

        feedTone(d, ms: 500)
        feedSilence(d, ms: 3500) // first stall
        feedTone(d, ms: 500)
        feedSilence(d, ms: 3500) // second stall

        XCTAssertEqual(starts.count, 2)
        XCTAssertGreaterThan(starts[1], starts[0], "second utterance should start later")
    }

    func testReplayIsCappedAtTenSeconds() {
        let d = makeCalibratedDetector()
        var ranges: [StallDetector.SampleRange] = []
        d.onStall = { start, end in ranges.append(.init(start: start, end: end)) }

        // 15 s of continuous speech with only short dips between words (no phrase gaps).
        feedSpeechLike(d, ms: 15_000)
        feedSilence(d, ms: 3500)

        XCTAssertEqual(ranges.count, 1)
        let durationMs = Double(ranges[0].count) * 1000.0 / Double(sampleRate)
        XCTAssertEqual(durationMs, 10_000, accuracy: 30, "cap includes pads and equals maxReplayMs")
    }

    func testLastUtteranceAvailableDuringSpeechAndPause() {
        let d = makeCalibratedDetector()
        XCTAssertNil(d.lastUtterance())
        feedTone(d, ms: 500)
        let during = d.lastUtterance()
        XCTAssertNotNil(during)
        feedSilence(d, ms: 500)
        let paused = d.lastUtterance()
        XCTAssertNotNil(paused)
        XCTAssertEqual(d.state, .paused)
        XCTAssertGreaterThan(paused!.end, during!.start)
    }

    func testResetUtteranceClearsPendingSpeech() {
        let d = makeCalibratedDetector()
        var stalled = 0
        d.onStall = { _, _ in stalled += 1 }
        feedTone(d, ms: 500)
        XCTAssertNotNil(d.lastUtterance())
        d.resetUtterance(newPos: d.position)
        XCTAssertNil(d.lastUtterance())
        XCTAssertEqual(d.state, .listening)
        feedSilence(d, ms: 4000)
        XCTAssertEqual(stalled, 0)
    }

    func testAdaptiveNoiseFloorStaysInBoundsAfterCalibration() {
        let d = StallDetector(sampleRate: sampleRate)
        var seed: UInt64 = 7
        // Very quiet input calibrates to max(observed, -75), then is clamped to [-80, -25].
        feedNoise(d, ms: 200, amplitude: 0.00005, seed: &seed) // ≈ -90 dBFS
        XCTAssertEqual(d.noiseFloorDb, -75, accuracy: 0.05)
        feedNoise(d, ms: 500, amplitude: 0.00005, seed: &seed)
        XCTAssertGreaterThanOrEqual(d.noiseFloorDb, -80)
        XCTAssertLessThanOrEqual(d.noiseFloorDb, -25)
        XCTAssertEqual(d.noiseFloorDb, -80, accuracy: 0.5, "quiet input pulls the floor down, never past -80")
    }

    func testOnsetRequiresSustainedEnergy() {
        let d = makeCalibratedDetector()
        // A single 20 ms frame is shorter than onsetMs (60), and the smoother
        // still sits well below the onset threshold after a stretch of silence.
        d.process(tone(samples: frame, amplitude: 0.2))
        XCTAssertEqual(d.state, .listening)
        // After ~200 ms of sustained tone the smoother has risen and onset trips.
        feedTone(d, ms: 200, amplitude: 0.2)
        XCTAssertEqual(d.state, .speaking)
    }

    func testLevelDbUpdates() {
        let d = makeCalibratedDetector()
        let silentDb = d.levelDb
        feedTone(d, ms: 200, amplitude: 0.3)
        XCTAssertGreaterThan(d.levelDb, silentDb)
        XCTAssertGreaterThan(d.levelDb, -40)
    }

    // MARK: - Added in 0.2 review

    /// Regression: a steady noise that starts after calibration (fan, air conditioner)
    /// used to hold the detector in "speaking" forever, so replay never fired again.
    func testSteadyNoiseAfterQuietCalibrationDoesNotStickInSpeaking() {
        let d = makeCalibratedDetector()
        var stalls = 0
        d.onStall = { _, _ in stalls += 1 }
        var seed: UInt64 = 1
        feedNoise(d, ms: 20_000, amplitude: 0.006, seed: &seed) // ≈ -49 dBFS fan
        XCTAssertNotEqual(d.state, .speaking, "steady noise must not count as endless speech")
        XCTAssertLessThanOrEqual(stalls, 1, "at most one false replay while the floor adapts")
        let before = stalls
        feedNoise(d, ms: 10_000, amplitude: 0.006, seed: &seed)
        XCTAssertEqual(stalls, before, "once adapted, steady noise triggers nothing")
        XCTAssertGreaterThan(d.noiseFloorDb, -56)
    }

    /// Regression: all-zero buffers at engine start used to calibrate the floor to -75 dB,
    /// so ordinary room noise then looked like speech.
    func testDigitalSilenceAtStartDoesNotCalibrateFloor() {
        let d = StallDetector(sampleRate: sampleRate)
        var stalls = 0
        d.onStall = { _, _ in stalls += 1 }
        for _ in 0..<15 { d.process(silence(frame)) }
        var seed: UInt64 = 3
        feedNoise(d, ms: 10_000, amplitude: 0.006, seed: &seed)
        XCTAssertEqual(stalls, 0)
        XCTAssertEqual(d.state, .listening)
        XCTAssertNil(d.lastUtterance())
    }

    func testSpeechStillDetectedOverAdaptedNoise() {
        let d = StallDetector(sampleRate: sampleRate)
        var seed: UInt64 = 5
        feedNoise(d, ms: 3000, amplitude: 0.006, seed: &seed)
        var ranges: [StallDetector.SampleRange] = []
        d.onStall = { s, e in ranges.append(.init(start: s, end: e)) }
        // Speech about 25 dB above the noise, then the noise continues.
        feedSpeechLike(d, ms: 1500, amplitude: 0.12)
        feedNoise(d, ms: 3600, amplitude: 0.006, seed: &seed)
        XCTAssertEqual(ranges.count, 1)
        let ms = Double(ranges[0].count) * 1000.0 / Double(sampleRate)
        XCTAssertGreaterThan(ms, 1200)
        XCTAssertLessThan(ms, 2500)
    }

    /// A long monologue made of phrases joined by short gaps: the 10 s cap should start
    /// at a phrase boundary, not in the middle of a word.
    func testCappedReplayStartsAtPhraseBoundary() {
        let d = makeCalibratedDetector()
        var ranges: [StallDetector.SampleRange] = []
        d.onStall = { s, e in ranges.append(.init(start: s, end: e)) }
        var phraseStarts: [Int64] = []
        for _ in 0..<6 {             // 6 × (2.3 s phrase + 0.5 s gap) ≈ 16.8 s, all joined
            phraseStarts.append(d.position)
            feedSpeechLike(d, ms: 2300)
            feedSilence(d, ms: 500)
        }
        feedSilence(d, ms: 3500)
        XCTAssertEqual(ranges.count, 1)
        let r = ranges[0]
        let ms = Double(r.count) * 1000.0 / Double(sampleRate)
        XCTAssertLessThanOrEqual(ms, 10_000 + 1)
        XCTAssertGreaterThan(ms, 5000)
        let pre = d.samples(forMs: d.prePadMs)
        let onsetSlack = d.samples(forMs: 120)
        XCTAssertTrue(phraseStarts.contains { abs((r.start + pre) - $0) <= onsetSlack },
                      "replay should start just before a phrase onset")
    }

    func testCancelPendingStallKeepsUtteranceForManualReplay() {
        let d = makeCalibratedDetector()
        var stalls = 0
        d.onStall = { _, _ in stalls += 1 }
        feedSpeechLike(d, ms: 800)
        d.cancelPendingStall()
        feedSilence(d, ms: 4000)
        XCTAssertEqual(stalls, 0, "no auto-replay after resuming")
        XCTAssertNotNil(d.lastUtterance(), "manual replay still possible")
        XCTAssertEqual(d.state, .listening)
        // New speech after the cancel is a fresh utterance and stalls normally.
        feedSpeechLike(d, ms: 800)
        feedSilence(d, ms: 3500)
        XCTAssertEqual(stalls, 1)
    }

    func testSegmentListResetsBetweenUtterances() {
        let d = makeCalibratedDetector()
        var starts: [Int64] = []
        d.onStall = { s, _ in starts.append(s) }
        feedSpeechLike(d, ms: 12_000)
        feedSilence(d, ms: 3500)
        let second = d.position
        feedSpeechLike(d, ms: 600)
        feedSilence(d, ms: 3500)
        XCTAssertEqual(starts.count, 2)
        XCTAssertGreaterThanOrEqual(starts[1], second - d.samples(forMs: d.prePadMs))
    }
}
