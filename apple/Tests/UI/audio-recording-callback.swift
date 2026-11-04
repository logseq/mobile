import AVFoundation
import Foundation
@testable import Logseq

private final class AudioUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var updates = 0
    private var failure: String?
    func receive(_ seconds: Int, _ level: Float, _ error: String?) {
        lock.lock()
        defer { lock.unlock() }
        precondition(!Thread.isMainThread, "Audio callbacks must run off the main actor")
        updates += 1
        failure = error
    }
    func verify() {
        lock.lock()
        defer { lock.unlock() }
        precondition(updates > 0, "The tap did not consume microphone buffers")
        precondition(failure == nil, "Writing microphone audio failed: \(failure ?? "")")
    }
}

@main struct CheckAudioRecordingCallback {
    @MainActor static func main() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let updates = AudioUpdates()
        let sink = RecordingAudioSink(file: try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 1,
        ])) { updates.receive($0, $1, $2) }
        // Deliberately obtain the actual production callback on MainActor,
        // then invoke it on the audio queue, as in the device crash reports.
        let callback = sink.makeTapHandler()
        try await Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = 0.1 }
            for index in 0..<5 {
                callback(buffer, AVAudioTime(sampleTime: Int64(index * 4_800), atRate: 48_000))
            }
            sink.close()
            // A callback already queued when Stop was pressed must be harmless.
            callback(buffer, AVAudioTime(sampleTime: 24_000, atRate: 48_000))
            updates.verify()
            let saved = try AVAudioFile(forReading: url)
            precondition(saved.length > 0, "The saved recording is empty")
        }.value
        print("PASS: main-actor-created recording tap safely writes audio on a background thread and tolerates late callbacks")
    }
}
