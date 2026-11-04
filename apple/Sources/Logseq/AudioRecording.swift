import Foundation

enum AudioRecordingPolicy {
    static let maximumDurationSeconds = 10 * 60
    static let fileExtension = "m4a"

    static func fileName(stamp: String) -> String {
        "Audio-\(stamp).\(fileExtension)"
    }

    static func elapsedTitle(seconds: Int) -> String {
        let bounded = max(0, min(seconds, maximumDurationSeconds))
        return String(format: "%02d:%02d", bounded / 60, bounded % 60)
    }

    static func supportsTranscription(iOSMajorVersion: Int) -> Bool {
        iOSMajorVersion >= 26
    }
}

#if os(iOS)
import AVFoundation
import CryptoKit
import Speech
import SwiftUI

struct RecordedAudioAsset: Sendable {
    let title: String
    let size: Int
    let checksum: String
    let path: String
}

// The tap is serial. Stop the engine and remove the tap before closing its file.
final class RecordingAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    var file: AVAudioFile?
    var consume: (@Sendable (AVAudioPCMBuffer) -> Void)?
    let onUpdate: @Sendable (Int, Float, String?) -> Void
    private var frames: AVAudioFramePosition = 0
    private var lastUpdate = 0

    init(file: AVAudioFile, onUpdate: @escaping @Sendable (Int, Float, String?) -> Void) {
        self.file = file
        self.onUpdate = onUpdate
    }

    // AVAudioEngine invokes taps off the main actor. Keep callback creation
    // outside the controller's actor context, including in Swift 6 builds.
    func makeTapHandler() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buffer, _ in append(buffer) }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard file != nil else { return }
        do {
            try file?.write(from: buffer)
            consume?(buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
            let seconds = Int(Double(frames) / buffer.format.sampleRate)
            let tick = Int(Double(frames) / buffer.format.sampleRate * 10)
            if tick != lastUpdate {
                lastUpdate = tick
                let samples = buffer.floatChannelData?[0]
                var peak: Float = 0
                if let samples {
                    for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
                }
                onUpdate(seconds, min(1, peak * 5), nil)
            }
        } catch {
            onUpdate(0, 0, error.localizedDescription)
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        consume = nil
    }
}

private final class ConverterInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}

@available(iOS 26.0, *)
@MainActor
private final class LiveAudioTranscription {
    let analyzer: SpeechAnalyzer
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?

    init(locale: Locale, inputFormat: AVAudioFormat, sink: RecordingAudioSink,
         onText: @escaping @MainActor (String) -> Void,
         onError: @escaping @MainActor (String) -> Void) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(locale), reserved.count >= AssetInventory.maximumReservedLocales {
            for stale in reserved where stale != locale {
                await AssetInventory.release(reservedLocale: stale)
            }
        }
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw CocoaError(.featureUnsupported)
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        resultsTask = Task {
            var finalText = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalText += text
                        onText(finalText)
                    } else {
                        onText(finalText + text)
                    }
                }
            } catch {
                if !Task.isCancelled { onError(error.localizedDescription) }
            }
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel()
            throw error
        }
        sink.consume = { [weak sink] buffer in
            do {
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / inputFormat.sampleRate))
                guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                    throw CocoaError(.fileReadUnknown)
                }
                let input = ConverterInput(buffer)
                var error: NSError?
                converter.convert(to: converted, error: &error) { @Sendable _, status in
                    input.take(status)
                }
                if let error { throw error }
                if converted.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: converted)) }
            } catch {
                sink?.consume = nil
                Task { @MainActor in onError(error.localizedDescription) }
            }
        }
    }

    func finish() async throws {
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
    }

    func cancel() async {
        continuation.finish()
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
    }
}

@MainActor
final class AudioRecorderController: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var hasRecording = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var liveTranscript = ""
    @Published private(set) var errorMessage: String?
    private var engine: AVAudioEngine?
    private var sink: RecordingAudioSink?
    private var outputURL: URL?
    private var transcription: AnyObject?
    private var interruptionObserver: NSObjectProtocol?

    func start(locale: Locale = .current, transcriptionLocale: Locale? = nil) async {
        guard !isRecording, !isPreparing, !hasRecording else { return }
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard granted else {
            errorMessage = CaptureLocalization.text("Microphone access is required to record audio.", locale: locale)
            return
        }
        do {
            try Task.checkCancellation()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Assets", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let url = directory.appendingPathComponent(AudioRecordingPolicy.fileName(stamp: formatter.string(from: Date())))
            outputURL = url
            let engine = AVAudioEngine()
            let format = engine.inputNode.outputFormat(forBus: 0)
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            let sink = RecordingAudioSink(file: file) { [weak self] seconds, level, failure in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    if let failure {
                        self.errorMessage = failure
                        self.pauseCapture()
                    } else {
                        self.elapsedSeconds = min(seconds, AudioRecordingPolicy.maximumDurationSeconds)
                        self.level = level
                        if seconds >= AudioRecordingPolicy.maximumDurationSeconds { self.pauseCapture() }
                    }
                }
            }
            self.sink = sink
            if #available(iOS 26.0, *), let transcriptionLocale {
                transcription = try await LiveAudioTranscription(
                    locale: transcriptionLocale, inputFormat: format, sink: sink,
                    onText: { [weak self] in self?.liveTranscript = $0 },
                    onError: { [weak self] in self?.errorMessage = $0 }
                )
            }
            try Task.checkCancellation()
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format,
                                        block: sink.makeTapHandler())
            self.engine = engine
            engine.prepare()
            try engine.start()
            hasRecording = true
            isRecording = true
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: .main
            ) { [weak self] notification in
                guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.pauseCapture() }
            }
        } catch {
            cancel()
            if !(error is CancellationError) {
                errorMessage = CaptureLocalization.text("Couldn't start recording.", locale: locale) + " " + error.localizedDescription
            }
        }
    }

    private func pauseCapture() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        sink?.close()
        isRecording = false
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
    }

    func stop() async throws -> RecordedAudioAsset? {
        guard hasRecording, let outputURL else { return nil }
        pauseCapture()
        if #available(iOS 26.0, *), let transcription = transcription as? LiveAudioTranscription {
            do { try await transcription.finish() }
            catch {
                errorMessage = error.localizedDescription
                await transcription.cancel()
            }
        }
        transcription = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let data = try Data(contentsOf: outputURL)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return RecordedAudioAsset(title: outputURL.lastPathComponent, size: data.count,
                                  checksum: checksum, path: outputURL.path)
    }

    func cancel() {
        pauseCapture()
        if #available(iOS 26.0, *), let transcription = transcription as? LiveAudioTranscription {
            Task { await transcription.cancel() }
        }
        transcription = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
        hasRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct AudioRecorderSheet: View {
    let targetBlockID: String?
    let onSave: (RecordedAudioAsset, String?, String?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @StateObject private var recorder = AudioRecorderController()
    @AppStorage("audio.transcription.enabled") private var transcriptionEnabled = true
    @AppStorage("audio.transcription.language") private var language = ""
    @State private var languages: [Locale] = []
    @State private var isSaving = false
    @State private var didSave = false
    @State private var saveError: String?
    @State private var startTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(AudioRecordingPolicy.elapsedTitle(seconds: recorder.elapsedSeconds))
                    .font(.system(size: 42, weight: .medium, design: .rounded))
                    .monospacedDigit()
                waveform.frame(height: 60)
                if !languages.isEmpty {
                    VStack(spacing: 12) {
                        Toggle(CaptureLocalization.text("Transcribe recording", locale: locale), isOn: $transcriptionEnabled)
                            .accessibilityIdentifier("toggle.audio.transcription")
                        if transcriptionEnabled {
                            Picker(CaptureLocalization.text("Transcription language", locale: locale), selection: $language) {
                                ForEach(languages, id: \.identifier) { item in
                                    Text(locale.localizedString(forIdentifier: item.identifier) ?? item.identifier)
                                        .tag(item.identifier)
                                }
                            }
                            .accessibilityIdentifier("picker.audio.language")
                        }
                    }
                    .disabled(recorder.hasRecording || recorder.isPreparing)
                }
                if recorder.isPreparing {
                    ProgressView(CaptureLocalization.text("Preparing transcription…", locale: locale))
                }
                if recorder.hasRecording, transcriptionEnabled, !languages.isEmpty {
                    ScrollView {
                        Text(recorder.liveTranscript.isEmpty
                             ? CaptureLocalization.text("Listening…", locale: locale) : recorder.liveTranscript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("audio.transcript")
                    }
                    .defaultScrollAnchor(.bottom)
                }
                Button {
                    if recorder.hasRecording {
                        Task { await save() }
                    } else {
                        startTask = Task {
                            await recorder.start(locale: locale, transcriptionLocale: transcriptionEnabled && !language.isEmpty
                                                 ? Locale(identifier: language) : nil)
                        }
                    }
                } label: {
                    ZStack {
                        Circle().fill(Color.red).frame(width: 72, height: 72)
                        Image(systemName: recorder.hasRecording ? "stop.fill" : "mic.fill").foregroundStyle(.white)
                    }
                }
                .disabled(recorder.isPreparing || isSaving)
                .accessibilityIdentifier(recorder.hasRecording ? "button.audio.stop" : "button.audio.start")
                .accessibilityLabel(CaptureLocalization.text(recorder.hasRecording ? "Stop recording" : "Start recording", locale: locale))
                if let error = saveError ?? recorder.errorMessage {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("audio.recording.error")
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle(CaptureLocalization.text("Audio recording", locale: locale))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(CaptureLocalization.text("Cancel", locale: locale)) {
                        startTask?.cancel()
                        recorder.cancel()
                        dismiss()
                    }
                    .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(recorder.hasRecording || recorder.isPreparing || isSaving)
        .task {
            if #available(iOS 26.0, *), SpeechTranscriber.isAvailable {
                languages = await SpeechTranscriber.supportedLocales.sorted {
                    (locale.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                        .localizedStandardCompare(locale.localizedString(forIdentifier: $1.identifier) ?? $1.identifier) == .orderedAscending
                }
                if !languages.contains(where: { $0.identifier == language }) {
                    language = await SpeechTranscriber.supportedLocale(equivalentTo: .current)?.identifier
                        ?? languages.first?.identifier ?? ""
                }
            }
        }
        .onDisappear {
            startTask?.cancel()
            if !didSave { recorder.cancel() }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if let asset = try await recorder.stop() {
                let transcript = recorder.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                try onSave(asset, targetBlockID, transcriptionEnabled && !transcript.isEmpty ? transcript : nil)
                didSave = true
                dismiss()
            }
        } catch {
            saveError = CaptureLocalization.text("Couldn't save the recording.", locale: locale) + " " + error.localizedDescription
        }
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<17, id: \.self) { index in
                let variation = Float((index % 5) + 1) / 5
                Capsule().fill(Color.accentColor)
                    .frame(width: 4, height: max(8, 64 * CGFloat(recorder.level * variation)))
            }
        }
        .animation(.linear(duration: 0.1), value: recorder.level)
    }
}
#endif
