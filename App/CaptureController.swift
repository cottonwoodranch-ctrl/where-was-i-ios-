import AVFoundation
import Combine
import SwiftUI
import UIKit
import WhereWasICore

/// Foreground-only capture loop: listen, detect a stall, replay the last utterance.
///
/// Threading: the microphone tap converts audio on the audio thread and hands it straight
/// to `ListeningPipeline`, which frames it, keeps the 30 s in-memory ring buffer and runs
/// the stall detector on its own serial queue. The main actor only receives a small state
/// snapshot about 20 times a second and the PCM to play when a stall fires.
/// All audio stays in memory. Capture is off while a replay plays, so the app never hears itself.
@MainActor
final class CaptureController: ObservableObject {
    nonisolated static let sampleRate = 16_000
    /// Ignore the microphone this long after a replay ends (replay tail / room echo).
    static let postPlaybackHoldoff: TimeInterval = 0.35
    /// With VoiceOver on, announce first and wait this long so speech and replay don't overlap.
    static let voiceOverLeadIn: TimeInterval = 1.0
    private static let stallSecondsKey = "stallSeconds"

    @Published private(set) var phase: ListeningPhase = .starting
    @Published private(set) var level: Double = 0
    @Published private(set) var canReplay = false
    @Published private(set) var isPlaying = false
    @Published private(set) var userPaused = false
    @Published var stallSeconds: Double = 3 {
        didSet {
            guard stallSeconds != oldValue else { return }
            pipeline.setStallSeconds(stallSeconds)
            UserDefaults.standard.set(stallSeconds, forKey: Self.stallSecondsKey)
            selectionHaptic.selectionChanged()
        }
    }

    var permissionDenied: Bool { phase == .needsPermission }

    nonisolated let pipeline = ListeningPipeline(sampleRate: CaptureController.sampleRate)
    /// `var` so the whole graph can be rebuilt after a media-services reset (Apple requires
    /// re-creating every AVAudio object then; the old ones are invalid).
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let replayHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let toggleHaptic = UIImpactFeedbackGenerator(style: .light)
    private let selectionHaptic = UISelectionFeedbackGenerator()

    private var running = false
    private var starting = false
    private var interrupted = false
    private var playerFormat: AVAudioFormat?
    private var observers: [NSObjectProtocol] = []
    private var playbackToken = 0

    init() {
        if UserDefaults.standard.object(forKey: Self.stallSecondsKey) != nil {
            let saved = UserDefaults.standard.double(forKey: Self.stallSecondsKey)
            stallSeconds = min(6, max(2, saved))
        }
        pipeline.setStallSeconds(stallSeconds)
        pipeline.onStall = { [weak self] pcm, range in
            Task { @MainActor [weak self] in
                self?.play(pcm: pcm, range: range, automatic: true)
            }
        }
        pipeline.onSnapshot = { [weak self] snap in
            Task { @MainActor [weak self] in
                self?.apply(snap)
            }
        }
        playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        )
        configureGraph()
        installObservers()
    }

    /// Attach the replay player to the (current) engine.
    private func configureGraph() {
        engine.attach(player)
        if let playerFormat {
            engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
        }
    }

    deinit {
        for o in observers {
            NotificationCenter.default.removeObserver(o)
        }
    }

    // MARK: - Public actions

    /// Start listening if allowed (the scene became active, or onboarding finished).
    func start() {
        // iOS does not always post "interruption ended" (e.g. after a call the user
        // answered). Coming back to the foreground is our cue to try again.
        if running && interrupted {
            resumeAfterInterruption()
            return
        }
        guard !running, !starting else { return }
        if userPaused {
            setPhase(.stoppedByUser)
            return
        }
        starting = true
        requestMicrophone { [weak self] granted in
            guard let self else { return }
            self.starting = false
            if granted {
                self.beginSession()
            } else {
                self.setPhase(.needsPermission)
            }
        }
    }

    /// The app left the foreground: release the microphone.
    func stop() {
        guard running || isPlaying else { return }
        endCapture()
        if !userPaused { phase = .starting }
    }

    /// The single secondary control: pause or resume listening.
    func toggleListening() {
        toggleHaptic.impactOccurred()
        if userPaused || !running {
            userPaused = false
            start()
        } else {
            userPaused = true
            endCapture()
            setPhase(.stoppedByUser)
        }
    }

    func replayLast() {
        guard running, !isPlaying, let item = pipeline.replayable() else { return }
        play(pcm: item.0, range: item.1, automatic: false)
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - State

    private func setPhase(_ next: ListeningPhase) {
        if phase != next { phase = next }
    }

    private func apply(_ snap: ListeningPipeline.Snapshot) {
        guard running, !isPlaying, !interrupted else { return }
        setPhase(.live(snap.state))
        level = snap.level
        if canReplay != snap.canReplay { canReplay = snap.canReplay }
    }

    private func endCapture() {
        running = false
        isPlaying = false
        playbackToken += 1
        level = 0
        canReplay = false
        pipeline.setAccepting(false)
        // Whatever was pending must not auto-play when listening resumes.
        pipeline.cancelPendingStall()
        tearDownAudio()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Permission

    private func requestMicrophone(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            let already = AVAudioApplication.shared.recordPermission
            switch already {
            case .granted:
                completion(true)
            case .denied:
                completion(false)
            default:
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in completion(granted) }
                }
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted:
                completion(true)
            case .denied:
                completion(false)
            case .undetermined:
                session.requestRecordPermission { granted in
                    Task { @MainActor in completion(granted) }
                }
            @unknown default:
                completion(false)
            }
        }
    }

    // MARK: - Session / engine

    private func beginSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Bluetooth HFP input (raw value 0x4). Xcode 26 renamed `.allowBluetooth` to
            // `.allowBluetoothHFP` (same value, any iOS version) and Xcode 16 lacks the new
            // name, so the raw value builds warning-free on both SDKs.
            let bluetooth = AVAudioSession.CategoryOptions(rawValue: 0x4)
            // .defaultToSpeaker uses the loudspeaker instead of the earpiece when nothing else
            // is connected, but still honours AirPods / wired / car audio routes.
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, bluetooth])
            // Without this, iOS silences haptics while the microphone is recording.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true, options: [])

            // Time that passed while we were not listening is not in the sample clock.
            pipeline.cancelPendingStall()
            try startEngineWithTap()
            running = true
            interrupted = false
            pipeline.setAccepting(true)
            UIApplication.shared.isIdleTimerDisabled = true
            setPhase(.listening)
        } catch {
            running = false
            setPhase(.unavailable)
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in self?.handleInterruption(typeRaw: typeRaw) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] _ in
            // Only restarts a stopped engine. A format change on a running engine arrives
            // as AVAudioEngineConfigurationChange below; reinstalling the tap here, while the
            // engine still runs with the old format, can raise a format-mismatch exception.
            Task { @MainActor [weak self] in self?.restartAfterAudioChange(configurationChanged: false) }
        })
        // Posted when the hardware format changes (e.g. a Bluetooth headset connects).
        // The engine stops itself; it has to be restarted and the tap reinstalled.
        // Observed for any engine and filtered, because the engine is rebuilt after a reset.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let sender = note.object as? AVAudioEngine else { return }
            let senderID = ObjectIdentifier(sender)
            Task { @MainActor [weak self] in
                guard let self, senderID == ObjectIdentifier(self.engine) else { return }
                self.restartAfterAudioChange(configurationChanged: true)
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMediaServicesReset() }
        })
    }

    private func handleInterruption(typeRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            // Phone call, Siri, alarm, FaceTime: the system has stopped our audio.
            guard running else { return }
            interrupted = true
            if isPlaying { finishPlayback() }
            pipeline.setAccepting(false)
            pipeline.cancelPendingStall()
            level = 0
            setPhase(.interrupted)
        case .ended:
            guard running, interrupted else { return }
            resumeAfterInterruption()
        @unknown default:
            break
        }
    }

    private func resumeAfterInterruption() {
        guard running, interrupted else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            if engine.isRunning { engine.stop() } // the tap is reinstalled for the current format
            try startEngineWithTap()
            interrupted = false
            pipeline.cancelPendingStall()
            pipeline.setAccepting(true)
            setPhase(.listening)
        } catch {
            // Still held by the other app (call in progress): stay "interrupted"; the next
            // "ended" notification or return to the foreground tries again.
            setPhase(.interrupted)
        }
    }

    private func restartAfterAudioChange(configurationChanged: Bool) {
        guard running, !interrupted else { return }
        if engine.isRunning {
            // Plain route change on a healthy engine (e.g. headphones unplugged, same format):
            // the existing tap keeps working.
            guard configurationChanged else { return }
            engine.stop()
        }
        // The engine stopped, which also stopped the player node; a replay in progress
        // will not report completion, so end it here (otherwise the app stays "replaying").
        if isPlaying { finishPlayback() }
        do {
            try startEngineWithTap()
        } catch {
            setPhase(.unavailable)
        }
    }

    /// The media server restarted: every AVAudio object is now invalid. Rebuild the engine
    /// graph and, if we were listening, start a fresh session.
    private func handleMediaServicesReset() {
        let wasRunning = running
        if wasRunning { endCapture() }
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        configureGraph()
        if wasRunning { start() }
    }

    private func tearDownAudio() {
        engine.inputNode.removeTap(onBus: 0)
        if player.isPlaying { player.stop() }
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// (Re)install the input tap for the current hardware format and make sure the
    /// engine is running. Safe to call repeatedly.
    private func startEngineWithTap() throws {
        try installTap()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private struct NoMicrophoneInput: Error {}

    /// Throws when there is no usable input (no input route, or no converter for it), so the
    /// caller shows "Could not start the microphone" instead of a silent, deaf "Listening…".
    private func installTap() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else { throw NoMicrophoneInput() }
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        )
        guard let target, let conv = AVAudioConverter(from: hw, to: target) else {
            throw NoMicrophoneInput()
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: hw,
                         block: Self.makeTapBlock(converter: conv, pipeline: pipeline))
    }

    /// Built outside the main actor so the block is not main-actor isolated: it runs on the
    /// audio thread, converts with the tap's own converter, and hands plain `[Int16]` to the
    /// pipeline queue. Nothing in this path touches the main thread.
    nonisolated private static func makeTapBlock(
        converter: AVAudioConverter,
        pipeline: ListeningPipeline
    ) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let samples = convert(buffer, with: converter), !samples.isEmpty else { return }
            pipeline.ingest(samples)
        }
    }

    // MARK: - Playback

    private func play(pcm: [Int16], range: StallDetector.SampleRange, automatic: Bool) {
        guard running, !interrupted, !isPlaying, let format = playerFormat,
              let buffer = Self.pcmBuffer(from: pcm, format: format) else {
            // A stall that cannot be played must not leave input switched off.
            if automatic { pipeline.playbackFinished(holdoff: 0, resume: running && !interrupted) }
            return
        }
        if !engine.isRunning {
            do {
                try startEngineWithTap()
            } catch {
                // AVAudioPlayerNode.play() on a stopped engine raises an exception (crash).
                pipeline.playbackFinished(holdoff: 0, resume: true)
                return
            }
        }

        pipeline.willPlay(range)
        isPlaying = true
        canReplay = false
        level = 0
        setPhase(.replaying)
        playbackToken += 1
        let token = playbackToken

        if automatic { replayHaptic.impactOccurred() }

        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: Copy.replayAnnouncement)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.voiceOverLeadIn) { [weak self] in
                self?.startPlayer(buffer, token: token)
            }
        } else {
            startPlayer(buffer, token: token)
        }
    }

    private func startPlayer(_ buffer: AVAudioPCMBuffer, token: Int) {
        guard running, isPlaying, token == playbackToken, engine.isRunning else {
            if token == playbackToken, isPlaying { finishPlayback() }
            return
        }
        if player.isPlaying { player.stop() }
        player.reset()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, token == self.playbackToken else { return }
                self.finishPlayback()
            }
        }
        player.play()
    }

    private func finishPlayback() {
        guard isPlaying else { return }
        isPlaying = false
        playbackToken += 1
        if player.isPlaying { player.stop() }
        let resume = running && !interrupted
        pipeline.playbackFinished(holdoff: Self.postPlaybackHoldoff, resume: resume)
        if resume { setPhase(.listening) }
    }

    // MARK: - Format helpers

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Int16]? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var submitted = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if submitted {
                outStatus.pointee = .noDataNow
                return nil
            }
            submitted = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error { return nil }
        return int16(from: out)
    }

    nonisolated private static func int16(from buffer: AVAudioPCMBuffer) -> [Int16] {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return [] }
        var out = [Int16](repeating: 0, count: n)
        if let ch = buffer.int16ChannelData {
            let src = ch[0]
            for i in 0..<n { out[i] = src[i] }
        } else if let ch = buffer.floatChannelData {
            let src = ch[0]
            for i in 0..<n {
                let x = max(-1.0, min(1.0, Double(src[i])))
                out[i] = Int16((x * 32767.0).rounded())
            }
        }
        return out
    }

    nonisolated private static func pcmBuffer(from samples: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let n = samples.count
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(n)
        if let ch = buffer.floatChannelData {
            let dst = ch[0]
            for i in 0..<n {
                dst[i] = Float(samples[i]) / 32768.0
            }
        } else if let ch = buffer.int16ChannelData {
            let dst = ch[0]
            for i in 0..<n { dst[i] = samples[i] }
        }
        return buffer
    }
}
