import SwiftUI
import WidgetKit
import AppIntents
import ActivityKit

struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingActivityCard(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .widgetURL(URL(string: "logseq://audio"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Recording", systemImage: "waveform").foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingActivityTimer(attributes: context.attributes, state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.transcript.isEmpty ? "Listening…" : context.state.transcript)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .privacySensitive()
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(.red)
            } compactTrailing: {
                RecordingActivityTimer(attributes: context.attributes, state: context.state)
                    .font(.caption2).frame(width: 48)
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(.red)
            }
            .widgetURL(URL(string: "logseq://audio"))
        }
    }
}

private struct JournalEntry: TimelineEntry {
    let date: Date
}

private struct JournalTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> JournalEntry {
        JournalEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (JournalEntry) -> Void) {
        completion(JournalEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JournalEntry>) -> Void) {
        let now = Date.now
        let calendar = Calendar.current
        let nextDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: [JournalEntry(date: now)], policy: .after(nextDay)))
    }
}

private struct TodayJournalWidgetView: View {
    let entry: JournalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LOGSEQ")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(entry.date, format: .dateTime.month(.abbreviated).day())
                .font(.title2.weight(.bold))
            Text(entry.date, format: .dateTime.weekday(.wide))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Label("Open journal", systemImage: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "logseq://journal"))
    }
}

private struct CaptureWidgetView: View {
    let entry: JournalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(intent: OpenJournalIntent()) {
                HStack {
                    Text(entry.date, format: .dateTime.weekday(.wide))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer(minLength: 0)
                    Image(systemName: "book.closed").foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            Text("I have an idea…")
                .font(.headline).foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                action("Record Audio", icon: "waveform", intent: RecordAudioIntent())
                action("Quick Add", icon: "plus", intent: QuickAddIntent())
            }
        }
        .containerBackground(Color(red: 0, green: 0.17, blue: 0.21), for: .widget)
        .widgetURL(URL(string: "logseq://capture"))
    }

    private func action<I: AppIntent>(_ title: String, icon: String, intent: I) -> some View {
        Button(intent: intent) {
            Image(systemName: icon).font(.body.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

@available(iOS 18.0, *)
private struct QuickAddControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.logseq.logseq.quickAdd") {
            ControlWidgetButton(action: QuickAddIntent()) {
                Label("Quick Add", systemImage: "plus.circle")
            }
        }
        .displayName("Quick Add")
        .description("Open Logseq quick capture.")
    }
}

@available(iOS 18.0, *)
private struct RecordAudioControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.logseq.logseq.recordAudio") {
            ControlWidgetButton(action: RecordAudioIntent()) {
                Label("Record Audio", systemImage: "waveform")
            }
        }
        .displayName("Record Audio")
        .description("Start a recording in Logseq.")
    }
}

private struct TodayJournalWidget: Widget {
    let kind = "TodayJournalWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JournalTimelineProvider()) { entry in
            TodayJournalWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's Journal")
        .description("Open today's Logseq journal.")
        .supportedFamilies([.systemSmall])
    }
}

private struct CaptureWidget: Widget {
    let kind = "CaptureWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JournalTimelineProvider()) { entry in
            CaptureWidgetView(entry: entry)
        }
        .configurationDisplayName("Quick Capture")
        .description("Capture a block in today's Logseq journal.")
        .supportedFamilies([.systemSmall])
    }
}

@main struct LogseqWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayJournalWidget()
        CaptureWidget()
        RecordingLiveActivityWidget()
        if #available(iOS 18.0, *) {
            QuickAddControl()
            RecordAudioControl()
        }
    }
}
