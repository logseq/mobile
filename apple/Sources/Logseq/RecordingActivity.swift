#if os(iOS)
@preconcurrency import ActivityKit
import SwiftUI

public struct RecordingActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var elapsedSeconds: Int
        public var isRecording: Bool
        public var transcript: String

        public init(elapsedSeconds: Int, isRecording: Bool, transcript: String) {
            self.elapsedSeconds = max(0, elapsedSeconds)
            self.isRecording = isRecording
            // ActivityKit limits the entire encoded payload to 4 KB.
            self.transcript = String(String.UnicodeScalarView(transcript.unicodeScalars.suffix(400)))
        }
    }

    public var startedAt: Date
    public var maximumDuration: TimeInterval

    public init(startedAt: Date, maximumDuration: TimeInterval) {
        self.startedAt = startedAt
        self.maximumDuration = maximumDuration
    }

    var timerRange: ClosedRange<Date> { startedAt...startedAt.addingTimeInterval(max(0, maximumDuration)) }
}

struct RecordingActivityTimer: View {
    let attributes: RecordingActivityAttributes
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.isRecording {
                Text(timerInterval: attributes.timerRange, countsDown: false)
            } else {
                Text(String(format: "%02d:%02d", state.elapsedSeconds / 60, state.elapsedSeconds % 60))
            }
        }
        .monospacedDigit()
        .fixedSize()
    }
}

struct RecordingActivityCard: View {
    let attributes: RecordingActivityAttributes
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(state.isRecording ? "Recording" : "Recording paused", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                HStack(spacing: 7) {
                    Circle().fill(state.isRecording ? Color.red : Color.secondary).frame(width: 8, height: 8)
                    RecordingActivityTimer(attributes: attributes, state: state)
                }
                .font(.subheadline.weight(.medium))
            }
            Text(state.transcript.isEmpty ? "Listening…" : state.transcript)
                .font(.body)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .privacySensitive()
        }
        .padding(16)
    }
}

#if !WIDGET_EXTENSION
@MainActor
final class RecordingLiveActivity {
    private var activity: Activity<RecordingActivityAttributes>?
    private var pendingUpdate: Task<Void, Never>?
    private var latest = RecordingActivityAttributes.ContentState(elapsedSeconds: 0, isRecording: false, transcript: "")

    static func dismissStaleActivities() {
        for activity in Activity<RecordingActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start() {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = RecordingActivityAttributes(startedAt: .now, maximumDuration: TimeInterval(AudioRecordingPolicy.maximumDurationSeconds))
        latest = .init(elapsedSeconds: 0, isRecording: true, transcript: "")
        activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: latest, staleDate: nil))
    }

    func update(elapsedSeconds: Int, isRecording: Bool, transcript: String) {
        let next = RecordingActivityAttributes.ContentState(elapsedSeconds: elapsedSeconds, isRecording: isRecording, transcript: transcript)
        let changed = next.transcript != latest.transcript || next.isRecording != latest.isRecording
        latest = next
        // The system animates the timer. Only transcript or recording-state
        // changes need updates, coalesced to avoid waking the widget per sample.
        guard changed, pendingUpdate == nil, let activity else { return }
        pendingUpdate = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.activity?.id == activity.id else { return }
                let delivered = self.latest
                await activity.update(ActivityContent(state: delivered, staleDate: nil))
                guard self.activity?.id == activity.id else { return }
                if self.latest.transcript == delivered.transcript, self.latest.isRecording == delivered.isRecording {
                    self.pendingUpdate = nil
                    return
                }
            }
        }
    }

    func end() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        guard let activity else { return }
        self.activity = nil
        latest.isRecording = false
        let content = ActivityContent(state: latest, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }
}
#endif
#endif
