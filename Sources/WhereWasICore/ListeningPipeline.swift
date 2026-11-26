import Foundation

/// The whole audio-analysis path, off the main thread.
///
/// The microphone tap hands converted 16 kHz samples to `ingest(_:)` from the audio
/// thread. Framing, the ring buffer and the stall detector all run on `queue`, a private
/// serial queue, so the UI thread never does per-buffer work. The UI receives a small
/// `Snapshot` at most every `snapshotEverySamples` of audio (50 ms by default), and the
/// replay PCM when a stall fires. All audio stays in memory.
public final class ListeningPipeline: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var state: StallDetector.State
        /// 0...1 microphone level for the visual meter.
        public var level: Double
        public var canReplay: Bool
    }

    public let sampleRate: Int
    public let frameSamples: Int
    public let queue: DispatchQueue

    /// Called on `queue` when a stall fires, with the PCM to replay.
    public var onStall: (([Int16], StallDetector.SampleRange) -> Void)?
    /// Called on `queue`, throttled.
    public var onSnapshot: ((Snapshot) -> Void)?

    private let ring: RingBuffer
    private let detector: StallDetector
    private let clock: () -> TimeInterval
    private let snapshotEverySamples: Int
    private var remainder: [Int16] = []
    private var accepting = false
    private var ignoreUntil: TimeInterval = 0
    private var lastPlayed: StallDetector.SampleRange?
    private var samplesSinceSnapshot = 0

    public init(
        sampleRate: Int = 16_000,
        ringSeconds: Int = 30,
        frameSamples: Int = 320,
        snapshotEveryMs: Double = 50,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.sampleRate = sampleRate
        self.frameSamples = frameSamples
        self.clock = clock
        self.snapshotEverySamples = max(1, Int(snapshotEveryMs * Double(sampleRate) / 1000.0))
        queue = DispatchQueue(label: "com.iqbal.wherewasi.listening", qos: .userInitiated)
        ring = RingBuffer(capacitySamples: sampleRate * ringSeconds)
        detector = StallDetector(sampleRate: sampleRate)
        detector.onStall = { [weak self] start, end in
            self?.stallFired(start: start, end: end)
        }
    }

    // MARK: - Called from any thread

    /// Hand over converted microphone samples. Returns immediately.
    public func ingest(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in self?.process(samples) }
    }

    /// Start or stop accepting microphone input (stopped while replaying or paused).
    public func setAccepting(_ on: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.accepting = on
            if !on { self.remainder.removeAll(keepingCapacity: true) }
        }
    }

    public func setStallSeconds(_ seconds: Double) {
        queue.async { [weak self] in self?.detector.setStallSeconds(seconds) }
    }

    /// Never auto-replay what was pending (app paused, call). Manual replay still works.
    public func cancelPendingStall() {
        queue.async { [weak self] in
            guard let self else { return }
            self.detector.cancelPendingStall()
            self.remainder.removeAll(keepingCapacity: true)
        }
    }

    /// The utterance a manual "Replay" would play, with its PCM, or nil.
    /// Blocks briefly on the pipeline queue; never call it from `queue` itself.
    public func replayable() -> ([Int16], StallDetector.SampleRange)? {
        queue.sync {
            guard let r = replayableRange() else { return nil }
            let pcm = ring.read(start: r.start, end: r.end)
            return pcm.isEmpty ? nil : (pcm, r)
        }
    }

    /// Record that `range` is being played (so "Replay" can repeat it) and stop input.
    public func willPlay(_ range: StallDetector.SampleRange) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastPlayed = range
            self.accepting = false
            self.remainder.removeAll(keepingCapacity: true)
        }
    }

    /// Playback ended: forget the played utterance, ignore input for `holdoff` seconds
    /// (the replay's tail and room echo), then accept input again if `resume`.
    public func playbackFinished(holdoff: TimeInterval, resume: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.remainder.removeAll(keepingCapacity: true)
            self.detector.resetUtterance(newPos: self.ring.totalWritten)
            self.ignoreUntil = self.clock() + holdoff
            self.accepting = resume
            self.emitSnapshot()
        }
    }

    /// Wait until everything queued so far has been processed (tests, teardown).
    public func flush() {
        queue.sync {}
    }

    // MARK: - On `queue`

    private func process(_ samples: [Int16]) {
        guard accepting else { return }
        if clock() < ignoreUntil { return }
        remainder.append(contentsOf: samples)
        var offset = 0
        while remainder.count - offset >= frameSamples {
            let frame = Array(remainder[offset..<(offset + frameSamples)])
            offset += frameSamples
            ring.write(frame)
            detector.process(frame)
            samplesSinceSnapshot += frameSamples
            if !accepting { break } // a stall just fired and stopped input
        }
        if offset > 0 { remainder.removeFirst(offset) }
        if !accepting { remainder.removeAll(keepingCapacity: true) }
        if samplesSinceSnapshot >= snapshotEverySamples {
            samplesSinceSnapshot = 0
            emitSnapshot()
        }
    }

    private func stallFired(start: Int64, end: Int64) {
        let range = StallDetector.SampleRange(start: start, end: end)
        let pcm = ring.read(start: start, end: end)
        guard !pcm.isEmpty else { return }
        // Stop listening right away so nothing is analysed while the UI starts the replay.
        accepting = false
        lastPlayed = range
        onStall?(pcm, range)
    }

    private func replayableRange() -> StallDetector.SampleRange? {
        if let r = detector.lastUtterance(), ring.holds(start: r.start, end: r.end) { return r }
        if let r = lastPlayed, ring.holds(start: r.start, end: r.end) { return r }
        return nil
    }

    private func emitSnapshot() {
        let db = detector.levelDb
        let level = min(1, max(0, (db + 60) / 52)) // -60 dB → 0, -8 dB → 1
        onSnapshot?(Snapshot(state: detector.state, level: level, canReplay: replayableRange() != nil))
    }
}
