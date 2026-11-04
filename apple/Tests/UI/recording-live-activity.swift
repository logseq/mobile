import ActivityKit
import Foundation
import SwiftUI
import UIKit
@testable import Logseq

@main struct CheckRecordingLiveActivity {
    @MainActor static func main() async throws {
        let attributes = RecordingActivityAttributes(startedAt: .now.addingTimeInterval(-8), maximumDuration: 600)
        let transcript = String(repeating: "语音 transcription 👩🏽‍💻 ", count: 1_000)
        let state = RecordingActivityAttributes.ContentState(elapsedSeconds: 8, isRecording: true, transcript: transcript)
        let encoded = try JSONEncoder().encode(state)
        precondition(encoded.count < 4_096, "Recording activity exceeded ActivityKit's payload limit")
        let decoded = try JSONDecoder().decode(RecordingActivityAttributes.ContentState.self, from: encoded)
        precondition(decoded == state)
        precondition(state.transcript.hasSuffix("👩🏽‍💻 "), "The latest transcription was discarded")
        precondition(attributes.timerRange.upperBound.timeIntervalSince(attributes.startedAt) == 600)

        let coordinator = LGPlatformPresentationCoordinator()
        precondition(coordinator.presentAttachment("audio", targetBlockID: "original"))
        let request = coordinator.attachmentRequestID
        precondition(coordinator.presentAttachment("audio", targetBlockID: "second"))
        precondition(coordinator.attachmentRequestID == request && coordinator.attachmentTargetBlockID == "original",
                     "Returning from the lock screen replaced the active recording")

        let card = RecordingActivityCard(attributes: attributes, state: .init(
            elapsedSeconds: 8, isRecording: true,
            transcript: "Just out for a walk. Looks like someone’s opening a small café down the street."
        ))
        .frame(width: 370)
        .background(Color(red: 0, green: 0.17, blue: 0.21), in: RoundedRectangle(cornerRadius: 24))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let image = renderer.uiImage?.pngData() else { preconditionFailure("Recording activity did not render") }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try image.write(to: documents.appendingPathComponent("recording-live-activity.png"))
        print("PASS: lock-screen card renders, payload is bounded, and returning preserves the recording target")

        precondition(ActivityAuthorizationInfo().areActivitiesEnabled, "Live Activities must be enabled for this runtime check")
        let live = RecordingLiveActivity()
        let started = Date.now
        live.start()
        guard let active = Activity<RecordingActivityAttributes>.activities.first(where: { $0.attributes.startedAt >= started }) else {
            preconditionFailure("The recording Live Activity was not registered with the widget extension")
        }
        defer { live.end() }
        live.update(elapsedSeconds: 2, isRecording: true, transcript: "First words")
        live.update(elapsedSeconds: 3, isRecording: true, transcript: "Latest words")
        try await Task.sleep(for: .milliseconds(1_500))
        precondition(active.content.state.transcript == "Latest words", "Live transcript updates were not coalesced")
        live.update(elapsedSeconds: 4, isRecording: false, transcript: "Latest words")
        try await Task.sleep(for: .milliseconds(1_500))
        precondition(!active.content.state.isRecording, "An interrupted recording still appeared to be running")
        live.update(elapsedSeconds: 4, isRecording: false, transcript: "Pending update")
        live.end()
        try await Task.sleep(for: .milliseconds(1_500))
        precondition(active.activityState == .ended || active.activityState == .dismissed,
                     "Ending the recording left a stale activity")
        print("PASS: recording Live Activity starts, updates, pauses, and ends without stale queued updates")
    }
}
