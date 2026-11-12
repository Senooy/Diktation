// Two native audio sources, converted independently onto the same host-clock timeline.
// ScreenCaptureKit supplies Mac audio; AVCaptureSession supplies the selected microphone.
import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

@MainActor
final class MeetingCapture: ObservableObject {
    static let shared = MeetingCapture()
    @Published private(set) var preparingID: Int64?
    @Published private(set) var stoppingID: Int64?
    @Published private(set) var error: String?
    @Published private(set) var levels: [Double] = [0, 0]
    private var activeID: Int64?
    private var sink: MeetingAudioSink?
    private var stream: SCStream?
    private var preparation: Task<Void, Never>?

    func start(id: Int64, speakers: Int, microphone: String) {
        guard preparingID == nil, activeID == nil, stoppingID == nil else { return }
        preparingID = id
        error = nil
        preparation = Task { [self] in
            let output = MeetingAudioSink(id: id, meter: { [weak self] levels in
                Task { @MainActor in if self?.activeID == id { self?.levels = levels } }
            }, failure: { [weak self] message in
                Task { @MainActor in await self?.stop(id: id, failure: message) }
            })
            var capture: SCStream?
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard allowed else { throw CaptureFailure(tr("Autorisez le microphone dans Réglages Système → Confidentialité et sécurité → Microphone.", "Allow microphone access in System Settings → Privacy & Security → Microphone.")) }
                try Task.checkCancellation()
                // This call invokes the macOS screen/system-audio permission flow when needed.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard let display = content.displays.first else { throw CaptureFailure(tr("Aucun écran disponible pour la capture du son du Mac.", "No display is available for Mac audio capture.")) }
                let config = SCStreamConfiguration()
                config.width = 2; config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.showsCursor = false
                config.capturesAudio = true
                config.sampleRate = 16_000
                config.channelCount = 1
                config.excludesCurrentProcessAudio = true
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let newStream = SCStream(filter: filter, configuration: config, delegate: output)
                capture = newStream
                // Tiny screen frames are discarded immediately, never saved or sent to Rust.
                try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
                try await output.prepareMicrophone(name: microphone)
                try await newStream.startCapture()
                try Task.checkCancellation()
                try await output.startMicrophone()
                try Task.checkCancellation()
                let core = CoreModel.shared
                core.sendRaw("meeting_start", ["id": id, "speakers": speakers, "source": "microphone_system"])
                core.refresh()
                guard core.state.meetings.recording_id == id else {
                    throw CaptureFailure(core.state.meetings.error ?? tr("La réunion n’a pas pu démarrer.", "The meeting could not start."))
                }
                activeID = id
                sink = output; stream = newStream
                try output.activate()
            } catch {
                try? await capture?.stopCapture()
                await output.stopMicrophone()
                if activeID == id {
                    activeID = nil; sink = nil; stream = nil
                    CoreModel.shared.sendRaw("meeting_capture_failed", ["id": id, "error": error.localizedDescription])
                }
                if !(error is CancellationError) {
                    self.error = tr("Capture visio impossible : ", "Could not start meeting capture: ") + error.localizedDescription
                        + tr(" Vérifiez l’autorisation d’enregistrement de l’écran et du son système dans Réglages Système.", " Check Screen & System Audio Recording permission in System Settings.")
                }
            }
            preparingID = nil
            preparation = nil
        }
    }

    func cancelPreparation() { preparation?.cancel() }

    /// Stop both native streams and drain their audio callbacks before final transcription.
    func stop(id: Int64, failure: String? = nil, notifyCore: Bool = true) async {
        guard activeID == id, stoppingID == nil else { return }
        stoppingID = id
        let currentStream = stream
        let currentSink = sink
        var reason = failure
        do { try await currentStream?.stopCapture() }
        catch { reason = reason ?? error.localizedDescription }
        await currentSink?.stopMicrophone()
        activeID = nil; sink = nil; stream = nil; levels = [0, 0]
        if let reason { error = reason }
        if notifyCore {
            if let reason { CoreModel.shared.sendRaw("meeting_capture_failed", ["id": id, "error": reason]) }
            else { CoreModel.shared.sendRaw("meeting_stop", ["id": id]) }
        }
        stoppingID = nil
    }

    func handles(_ id: Int64) -> Bool { activeID == id }

    /// Core-side timeout or failure must also release the native capture devices.
    func reconcile(recordingID: Int64?) {
        guard let id = activeID, id != recordingID, stoppingID == nil else { return }
        Task { await stop(id: id, notifyCore: false) }
    }
}

private struct CaptureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// All sample/converter state is confined to `queue`; microphone setup uses `sessionQueue`.
private final class MeetingAudioSink: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "dev.local.diktation.meeting-audio", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "dev.local.diktation.meeting-mic", qos: .userInitiated)
    private let microphone = AVCaptureSession()
    private let id: Int64
    private let failure: (String) -> Void
    private let meter: ([Double]) -> Void
    private var levels: [Double] = [0, 0]
    private var lastMeter = 0.0
    private var observers: [NSObjectProtocol] = []
    private var epoch: Double?
    private var converters: [Int: MeetingPCMConverter] = [:]
    private var failed = false
    private var startupError: String?
    private var received = [false, false]
    private var watchdog: DispatchSourceTimer?

    init(id: Int64, meter: @escaping ([Double]) -> Void, failure: @escaping (String) -> Void) { self.id = id; self.meter = meter; self.failure = failure }

    func prepareMicrophone(name: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
                    let device = devices.first(where: { !$0.localizedName.isEmpty && $0.localizedName == name }) ?? AVCaptureDevice.default(for: .audio)
                    guard let device else { throw CaptureFailure(tr("Aucun microphone disponible.", "No microphone is available.")) }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    self.microphone.beginConfiguration()
                    defer { self.microphone.commitConfiguration() }
                    guard self.microphone.canAddInput(input), self.microphone.canAddOutput(output) else { throw CaptureFailure(tr("Ce microphone ne peut pas être capturé.", "This microphone cannot be captured.")) }
                    self.microphone.addInput(input); self.microphone.addOutput(output)
                    for notification in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                        self.observers.append(NotificationCenter.default.addObserver(forName: notification, object: self.microphone, queue: nil) { [weak self] note in
                            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                                ?? tr("Le microphone de la réunion a été interrompu.", "The meeting microphone was interrupted.")
                            self?.queue.async { [weak self] in self?.report(message) }
                        })
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func startMicrophone() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                self.microphone.startRunning()
                if self.microphone.isRunning { continuation.resume() }
                else { continuation.resume(throwing: CaptureFailure(tr("Le microphone n’a pas démarré.", "The microphone did not start."))) }
            }
        }
    }

    func activate() throws {
        try queue.sync {
            if let startupError { throw CaptureFailure(startupError) }
            epoch = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            failed = false; received = [false, false]
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 10)
            timer.setEventHandler { [weak self] in
                guard let self, self.epoch != nil else { return }
                if !self.received[0] { self.report(tr("Aucun signal reçu du microphone. Vérifiez le micro et ses autorisations.", "No microphone signal received. Check the microphone and its permissions.")) }
                // A silent Mac can legitimately produce no system-audio buffers.
            }
            watchdog = timer; timer.resume()
        }
    }

    func stopMicrophone() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
                self.observers.removeAll()
                self.microphone.stopRunning()
                self.queue.async {
                    self.epoch = nil
                    self.watchdog?.cancel(); self.watchdog = nil
                    self.converters.removeAll()
                    continuation.resume()
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        receive(sampleBuffer, track: 1, clock: stream.synchronizationClock)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.report(tr("Capture du son du Mac interrompue : ", "Mac audio capture stopped: ") + error.localizedDescription) }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        receive(sampleBuffer, track: 0, clock: microphone.synchronizationClock)
    }
    private func report(_ message: String) {
        guard !failed else { return }
        if epoch == nil { startupError = message; return }
        failed = true; failure(message)
    }
    private func receive(_ buffer: CMSampleBuffer, track: Int, clock: CMClock?) {
        guard let epoch, !failed, CMSampleBufferDataIsReady(buffer) else { return }
        guard let clock else { report(tr("Horloge audio indisponible.", "Audio clock unavailable.")); return }
        let time = CMSyncConvertTime(buffer.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock()).seconds - epoch
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds - epoch
        guard time.isFinite, time >= -2, time <= now + 2 else { report(tr("Horodatage audio invalide.", "Invalid audio timestamp.")); return }
        do {
            let converter = converters[track] ?? MeetingPCMConverter()
            converters[track] = converter
            let samples = try converter.convert(buffer)
            guard !samples.isEmpty else { return }
            received[track] = true
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
            levels[track] = min(1, max(0, (20 * log10(max(1e-8, rms)) + 60) / 48))
            if now - lastMeter > 0.2 { lastMeter = now; meter(levels) }
            let index = Int64((time * 16_000).rounded())
            let skip = min(samples.count, Int(max(0, -index)))
            guard skip < samples.count else { return }
            let offset = UInt64(max(0, index))
            // Late packets after a core-side stop are intentionally ignored.
            samples.withUnsafeBufferPointer { data in
                _ = dk_meeting_audio(id, UInt32(track), offset, data.baseAddress! + skip, data.count - skip)
            }
        } catch { report(error.localizedDescription) }
    }
}

/// Each device has its own converter: hardware format and rate may differ from Mac audio.
final class MeetingPCMConverter {
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func convert(_ sample: CMSampleBuffer) throws -> [Float] {
        guard let description = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { throw CaptureFailure("Unsupported audio format") }
        let frames = sample.numSamples
        guard frames > 0, frames <= Int(format.sampleRate * 2),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return [] }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { throw CaptureFailure("Audio buffer copy failed (\(status))") }
        return try convert(pcm)
    }

    func convert(_ pcm: AVAudioPCMBuffer) throws -> [Float] {
        if inputFormat != pcm.format {
            inputFormat = pcm.format
            converter = AVAudioConverter(from: pcm.format, to: target)
            converter?.primeMethod = .none
        }
        guard let converter else { throw CaptureFailure("Audio conversion unavailable") }
        let capacity = AVAudioFrameCount(ceil(Double(pcm.frameLength) * 16_000 / pcm.format.sampleRate) + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw CaptureFailure("Audio allocation failed") }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return pcm
        }
        guard status != .error, error == nil, let channels = output.floatChannelData else { throw error ?? CaptureFailure("Audio conversion failed") }
        return Array(UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength)))
    }
}
