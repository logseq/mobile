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

@MainActor
final class AudioRecorderController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var outputURL: URL?
    private var meterTask: Task<Void, Never>?

    func start() async {
        guard !isRecording else { return }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
        guard granted else {
            errorMessage = "Microphone access is required to record audio."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Assets", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let url = directory.appendingPathComponent(
                AudioRecordingPolicy.fileName(stamp: formatter.string(from: Date()))
            )
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: TimeInterval(AudioRecordingPolicy.maximumDurationSeconds)) else {
                throw CocoaError(.fileWriteUnknown)
            }
            self.recorder = recorder
            outputURL = url
            isRecording = true
            startMetering()
        } catch {
            errorMessage = "Couldn't start recording. \(error.localizedDescription)"
        }
    }

    func stop() throws -> RecordedAudioAsset? {
        guard let recorder, let outputURL else { return nil }
        recorder.stop()
        finishMetering()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let data = try Data(contentsOf: outputURL)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return RecordedAudioAsset(
            title: outputURL.lastPathComponent,
            size: data.count,
            checksum: checksum,
            path: outputURL.path
        )
    }

    func cancel() {
        recorder?.stop()
        finishMetering()
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.elapsedSeconds = min(
                    Int(recorder.currentTime), AudioRecordingPolicy.maximumDurationSeconds
                )
                self.level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 55) / 55))
                if !recorder.isRecording {
                    self.isRecording = false
                    return
                }
            }
        }
    }

    private func finishMetering() {
        meterTask?.cancel()
        meterTask = nil
        isRecording = false
    }

    @available(iOS 26.0, *)
    private static func modernTranscript(_ url: URL) async throws -> String {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let transcript = transcriber.results.reduce(into: "") { text, result in
            text += String(result.text.characters)
        }
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await transcript
    }

    func transcript(for url: URL) async throws -> String? {
        guard #available(iOS 26.0, *) else { return nil }
        return try await Self.modernTranscript(url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct AudioRecorderSheet: View {
    let targetBlockID: String?
    let onSave: (RecordedAudioAsset, String?, String?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = AudioRecorderController()
    @State private var transcriptionEnabled = true
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Text(AudioRecordingPolicy.elapsedTitle(seconds: recorder.elapsedSeconds))
                    .font(.system(size: 42, weight: .medium, design: .rounded))
                    .monospacedDigit()
                waveform
                    .frame(height: 72)
                if #available(iOS 26.0, *) {
                    Toggle("Transcribe recording", isOn: $transcriptionEnabled)
                        .accessibilityIdentifier("toggle.audio.transcription")
                }
                if let errorMessage = saveError ?? recorder.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                Button {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        if let asset = try? recorder.stop() {
                            let transcript = transcriptionEnabled
                                ? try? await recorder.transcript(for: URL(fileURLWithPath: asset.path))
                                : nil
                            do {
                                try onSave(asset, targetBlockID, transcript)
                                dismiss()
                            } catch {
                                saveError = "Couldn't save the recording. \(error.localizedDescription)"
                            }
                        }
                    }
                } label: {
                    ZStack {
                        Circle().fill(Color.red).frame(width: 72, height: 72)
                        Image(systemName: "stop.fill").foregroundStyle(.white)
                    }
                }
                .disabled(!recorder.isRecording || isSaving)
                .accessibilityLabel("Stop recording")
                Spacer()
            }
            .padding(24)
            .navigationTitle("Audio recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.cancel()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(recorder.isRecording)
        .task { await recorder.start() }
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<17, id: \.self) { index in
                let variation = Float((index % 5) + 1) / 5
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: max(8, 64 * CGFloat(recorder.level * variation)))
            }
        }
        .animation(.linear(duration: 0.1), value: recorder.level)
    }
}
#endif
