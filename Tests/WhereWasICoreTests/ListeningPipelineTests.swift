import XCTest
import Foundation
@testable import WhereWasICore

final class ListeningPipelineTests: XCTestCase {
    let sr = 16_000

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ v: T) { value = v }
    }

    func tone(ms: Double, amplitude: Double = 0.2) -> [Int16] {
        let n = Int(ms * Double(sr) / 1000)
        return (0..<n).map { i in
            Int16(max(-0.999, min(0.999, amplitude * sin(2 * Double.pi * 200 * Double(i) / Double(sr)))) * 32767)
        }
    }

    func quiet(ms: Double, seed: inout UInt64) -> [Int16] {
        let n = Int(ms * Double(sr) / 1000)
        return (0..<n).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let u = Double((seed >> 33) & 0xFFFF) / 65535.0 * 2 - 1
            return Int16(u * 0.0005 * 32767)
        }
    }

    /// Feed in 1024-sample chunks, like an audio tap (not aligned to 20 ms frames).
    func feed(_ p: ListeningPipeline, _ samples: [Int16]) {
        var i = 0
        while i < samples.count {
            let j = min(samples.count, i + 1024)
            p.ingest(Array(samples[i..<j]))
            i = j
        }
        p.flush()
    }

    func speechLike(ms: Double) -> [Int16] {
        var out: [Int16] = []
        var t = 0.0
        while t < ms {
            out += tone(ms: 200)
            out += [Int16](repeating: 0, count: Int(0.06 * Double(sr)))
            t += 260
        }
        return out
    }

    func makePipeline(clock: @escaping () -> TimeInterval = { 0 }) -> ListeningPipeline {
        let p = ListeningPipeline(clock: clock)
        p.setAccepting(true)
        var seed: UInt64 = 9
        feed(p, quiet(ms: 300, seed: &seed))
        return p
    }

    func testStallDeliversReplayPCMOffMainAndStopsInput() {
        let p = makePipeline()
        let got = Box<[Int]>([])
        let onMain = Box<Bool>(true)
        p.onStall = { pcm, _ in
            got.value.append(pcm.count)
            onMain.value = Thread.isMainThread
        }
        feed(p, speechLike(ms: 1000))
        var seed: UInt64 = 1
        feed(p, quiet(ms: 3600, seed: &seed))
        XCTAssertEqual(got.value.count, 1)
        XCTAssertFalse(onMain.value, "stall work must not run on the main thread")
        let ms = Double(got.value[0]) * 1000 / Double(sr)
        XCTAssertGreaterThan(ms, 900)
        XCTAssertLessThan(ms, 1800)
        // Input is stopped after a stall until playbackFinished: more speech does nothing.
        feed(p, speechLike(ms: 1000))
        feed(p, quiet(ms: 3600, seed: &seed))
        XCTAssertEqual(got.value.count, 1)
    }

    func testReplayAvailableAgainAfterAutoReplay() {
        let p = makePipeline()
        p.onStall = { _, _ in }
        feed(p, speechLike(ms: 800))
        var seed: UInt64 = 2
        feed(p, quiet(ms: 3600, seed: &seed))
        p.playbackFinished(holdoff: 0, resume: true)
        p.flush()
        let again = p.replayable()
        XCTAssertNotNil(again, "the replayed utterance can be played again")
        XCTAssertGreaterThan(again?.0.count ?? 0, 0)
    }

    func testHoldoffIgnoresInputRightAfterPlayback() {
        let now = Box<TimeInterval>(100)
        let p = makePipeline(clock: { now.value })
        let stalls = Box(0)
        p.onStall = { _, _ in stalls.value += 1 }
        p.playbackFinished(holdoff: 0.35, resume: true)
        p.flush()
        // "Echo" arrives during the hold-off and must be ignored entirely.
        feed(p, speechLike(ms: 300))
        var seed: UInt64 = 3
        now.value = 100.5
        feed(p, quiet(ms: 3600, seed: &seed))
        XCTAssertEqual(stalls.value, 0)
        XCTAssertNil(p.replayable())
    }

    func testNotAcceptingDropsInput() {
        let p = makePipeline()
        let stalls = Box(0)
        p.onStall = { _, _ in stalls.value += 1 }
        p.setAccepting(false)
        feed(p, speechLike(ms: 1000))
        var seed: UInt64 = 4
        feed(p, quiet(ms: 3600, seed: &seed))
        XCTAssertEqual(stalls.value, 0)
        XCTAssertNil(p.replayable())
    }

    func testCancelPendingStallKeepsManualReplay() {
        let p = makePipeline()
        let stalls = Box(0)
        p.onStall = { _, _ in stalls.value += 1 }
        feed(p, speechLike(ms: 800))
        p.cancelPendingStall()
        var seed: UInt64 = 5
        feed(p, quiet(ms: 3600, seed: &seed))
        XCTAssertEqual(stalls.value, 0)
        XCTAssertNotNil(p.replayable())
    }

    func testSnapshotsAreThrottledAndReportState() {
        let p = makePipeline()
        let snaps = Box<[ListeningPipeline.Snapshot]>([])
        p.onSnapshot = { snaps.value.append($0) }
        feed(p, speechLike(ms: 1000)) // 1 s of audio → about 20 snapshots at 50 ms
        XCTAssertGreaterThanOrEqual(snaps.value.count, 15)
        XCTAssertLessThanOrEqual(snaps.value.count, 25)
        XCTAssertTrue(snaps.value.contains { $0.state == .speaking })
        XCTAssertTrue(snaps.value.allSatisfy { (0...1).contains($0.level) })
        XCTAssertTrue(snaps.value.last?.canReplay ?? false)
    }
}

final class CopyTests: XCTestCase {
    func testLivePhaseMapping() {
        XCTAssertEqual(ListeningPhase.live(.listening), .listening)
        XCTAssertEqual(ListeningPhase.live(.speaking), .hearing)
        XCTAssertEqual(ListeningPhase.live(.paused), .paused)
        XCTAssertTrue(ListeningPhase.hearing.micIsLive)
        XCTAssertFalse(ListeningPhase.replaying.micIsLive)
        XCTAssertFalse(ListeningPhase.stoppedByUser.micIsLive)
    }

    func testEveryPhaseHasStatusText() {
        for phase in ListeningPhase.allCases {
            XCTAssertFalse(Copy.status(phase).isEmpty, "\(phase)")
        }
    }

    /// The same wording ships on Android (UiCopy.java); this pins the shared strings.
    func testWordingMatchesAndroid() {
        XCTAssertEqual(Copy.status(.listening), "Listening…")
        XCTAssertEqual(Copy.status(.hearing), "Hearing you…")
        XCTAssertEqual(Copy.status(.paused), "You paused…")
        XCTAssertEqual(Copy.status(.replaying), "Playing back what you said…")
        XCTAssertEqual(Copy.status(.stoppedByUser), "Listening is paused")
        XCTAssertEqual(Copy.replay, "Replay what I said")
        XCTAssertEqual(Copy.waitValue(3), "3.0 seconds")
        XCTAssertEqual(Copy.waitValue(4.5), "4.5 seconds")
    }
}
