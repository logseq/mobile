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

    static func transcriptionLocale(lastUsed: String, system: Locale = .current) -> Locale {
        lastUsed.isEmpty ? system : Locale(identifier: lastUsed)
    }

    static func appendTranscript(_ text: String, to prefix: String) -> String {
        [prefix, text].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
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
    private var consume: (@Sendable (AVAudioPCMBuffer) -> Void)?
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

    func setConsumer(_ consume: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        self.consume = consume
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
    let consume: @Sendable (AVAudioPCMBuffer) -> Void
    private var resultsTask: Task<Void, Never>?

    init(locale: Locale, inputFormat: AVAudioFormat,
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
        consume = { buffer in
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
                Task { @MainActor in onError(error.localizedDescription) }
            }
        }
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
    @Published private(set) var isPreparingTranscription = false
    @Published private(set) var hasRecording = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var liveTranscript = ""
    @Published private(set) var errorMessage: String?
    private var engine: AVAudioEngine?
    private var sink: RecordingAudioSink?
    private var outputURL: URL?
    private var transcription: AnyObject?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionGeneration = 0
    private var inputFormat: AVAudioFormat?
    private let liveActivity = RecordingLiveActivity()
    private var interruptionObserver: NSObjectProtocol?

    func start(locale: Locale = .current, transcriptionLocale: Locale? = nil) async {
        guard !isRecording, !isPreparing, !hasRecording else { return }
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { @Sendable granted in continuation.resume(returning: granted) }
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
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "LogseqAudioRecording", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The microphone input is unavailable."])
            }
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
                    self.updateLiveActivity()
                }
            }
            self.sink = sink
            inputFormat = format
            try Task.checkCancellation()
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format,
                                        block: sink.makeTapHandler())
            self.engine = engine
            engine.prepare()
            try engine.start()
            hasRecording = true
            isRecording = true
            liveActivity.start()
            setTranscriptionLanguage(transcriptionLocale)
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

    func setTranscriptionLanguage(_ locale: Locale?) {
        guard #available(iOS 26.0, *), isRecording, let sink, let inputFormat else { return }
        transcriptionGeneration += 1
        let generation = transcriptionGeneration
        transcriptionTask?.cancel()
        let previous = transcription as? LiveAudioTranscription
        transcription = nil
        sink.setConsumer(nil)
        let prefix = liveTranscript
        errorMessage = nil
        isPreparingTranscription = locale != nil
        transcriptionTask = Task { [self] in
            await previous?.cancel()
            guard !Task.isCancelled, generation == transcriptionGeneration, isRecording else { return }
            defer {
                if generation == transcriptionGeneration { isPreparingTranscription = false }
            }
            guard let locale else { return }
            do {
                guard SpeechTranscriber.isAvailable,
                      let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                    throw CocoaError(.featureUnsupported)
                }
                try Task.checkCancellation()
                let active = try await LiveAudioTranscription(
                    locale: supported, inputFormat: inputFormat,
                    onText: { [weak self] text in
                        guard let self, generation == self.transcriptionGeneration else { return }
                        self.liveTranscript = AudioRecordingPolicy.appendTranscript(text, to: prefix)
                        self.updateLiveActivity()
                    },
                    onError: { [weak self] message in
                        guard let self, generation == self.transcriptionGeneration else { return }
                        self.sink?.setConsumer(nil)
                        self.errorMessage = message
                    }
                )
                guard !Task.isCancelled, generation == transcriptionGeneration, isRecording else {
                    await active.cancel()
                    return
                }
                transcription = active
                sink.setConsumer(active.consume)
            } catch {
                if !(error is CancellationError), generation == transcriptionGeneration {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func pauseCapture() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        sink?.close()
        isRecording = false
        updateLiveActivity()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
    }

    private func updateLiveActivity() {
        liveActivity.update(elapsedSeconds: elapsedSeconds, isRecording: isRecording, transcript: liveTranscript)
    }

    func stop() async throws -> RecordedAudioAsset? {
        guard hasRecording, let outputURL else { return nil }
        transcriptionTask?.cancel()
        isPreparingTranscription = false
        pauseCapture()
        liveActivity.end()
        if #available(iOS 26.0, *), let transcription = transcription as? LiveAudioTranscription {
            do { try await transcription.finish() }
            catch {
                errorMessage = error.localizedDescription
                await transcription.cancel()
            }
        }
        transcription = nil
        transcriptionGeneration += 1
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let data = try Data(contentsOf: outputURL)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return RecordedAudioAsset(title: outputURL.lastPathComponent, size: data.count,
                                  checksum: checksum, path: outputURL.path)
    }

    func cancel() {
        liveActivity.end()
        transcriptionGeneration += 1
        transcriptionTask?.cancel()
        isPreparingTranscription = false
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
                    .disabled(recorder.isPreparing || isSaving)
                }
                if recorder.hasRecording, transcriptionEnabled, !languages.isEmpty || recorder.isPreparingTranscription {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if recorder.isPreparingTranscription {
                                ProgressView(CaptureLocalization.text("Preparing transcription…", locale: locale))
                            }
                            if !recorder.liveTranscript.isEmpty || !recorder.isPreparingTranscription {
                                Text(recorder.liveTranscript.isEmpty
                                     ? CaptureLocalization.text("Listening…", locale: locale) : recorder.liveTranscript)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("audio.transcript")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                }
                if let error = saveError ?? recorder.errorMessage {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("audio.recording.error")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(24)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                recordingButton.padding(.horizontal, 24).padding(.bottom, 24)
            }
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
        .task { startRecording() }
        .task {
            if #available(iOS 26.0, *), SpeechTranscriber.isAvailable {
                languages = await SpeechTranscriber.supportedLocales.sorted {
                    (locale.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                        .localizedStandardCompare(locale.localizedString(forIdentifier: $1.identifier) ?? $1.identifier) == .orderedAscending
                }
                if !languages.contains(where: { $0.identifier == language }) {
                    let preferred = await SpeechTranscriber.supportedLocale(equivalentTo: selectedTranscriptionLocale)
                    let system = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
                    language = preferred?.identifier ?? system?.identifier ?? languages.first?.identifier ?? ""
                }
            }
        }
        .onChange(of: language) { _, _ in updateTranscriptionLanguage() }
        .onChange(of: transcriptionEnabled) { _, _ in updateTranscriptionLanguage() }
        .onDisappear {
            startTask?.cancel()
            if !didSave { recorder.cancel() }
        }
    }

    private var selectedTranscriptionLocale: Locale {
        AudioRecordingPolicy.transcriptionLocale(lastUsed: language)
    }

    private var recordingButton: some View {
        Button {
            if recorder.hasRecording {
                Task { await save() }
            } else {
                startRecording()
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
    }

    private func startRecording() {
        startTask = Task {
            await recorder.start(locale: locale,
                                 transcriptionLocale: transcriptionEnabled ? selectedTranscriptionLocale : nil)
        }
    }

    private func updateTranscriptionLanguage() {
        recorder.setTranscriptionLanguage(transcriptionEnabled ? selectedTranscriptionLocale : nil)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if let asset = try await recorder.stop() {
                let transcript = recorder.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                try onSave(asset, targetBlockID, transcript.isEmpty ? nil : transcript)
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
