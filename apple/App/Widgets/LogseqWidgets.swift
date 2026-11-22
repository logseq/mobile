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

private struct GraphWidgetContent: Decodable {
    struct StatusChoice: Decodable, Identifiable {
        let uuid: String
        let title: String
        var id: String { uuid }
    }

    struct Block: Decodable, Identifiable {
        let uuid: String
        let title: String
        let status: String?
        var statusUuid: String? = nil
        var statusChoices: [StatusChoice]? = nil
        var id: String { uuid }
    }

    let graphId: String?
    var graphLocked: Bool? = nil
    let tasks: [Block]
    let randomBlocks: [Block]

    static var empty: Self { Self(graphId: nil, tasks: [], randomBlocks: []) }

    static func read() -> Self {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.logseq.logseq"
        ), let data = try? Data(contentsOf: container.appendingPathComponent("widget-content.json")),
           let content = try? JSONDecoder().decode(Self.self, from: data) else { return .empty }
        return content
    }
}

private struct GraphWidgetEntry: TimelineEntry {
    let date: Date
    let content: GraphWidgetContent
    let randomBlocks: [GraphWidgetContent.Block]
    var selection: WidgetTaskStatusSelection? = nil
}

private struct GraphWidgetProvider: TimelineProvider {
    let showsTasks: Bool

    func placeholder(in context: Context) -> GraphWidgetEntry {
        let task = GraphWidgetContent.Block(uuid: "task", title: "Review project notes", status: "Todo",
            statusUuid: "todo", statusChoices: [.init(uuid: "todo", title: "Todo"), .init(uuid: "doing", title: "Doing")])
        let block = GraphWidgetContent.Block(uuid: "block", title: "An idea worth revisiting", status: nil)
        return GraphWidgetEntry(date: .now,
            content: GraphWidgetContent(graphId: "preview", tasks: [task], randomBlocks: []),
            randomBlocks: [block])
    }

    func getSnapshot(in context: Context, completion: @escaping (GraphWidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GraphWidgetEntry>) -> Void) {
        let entry = entry()
        let policy: TimelineReloadPolicy
        if let selection = entry.selection {
            policy = .after(selection.expiresAt)
        } else if entry.content.graphId == nil {
            policy = .after(entry.date.addingTimeInterval(900))
        } else {
            policy = showsTasks ? .never : .after(entry.date.addingTimeInterval(3600))
        }
        completion(Timeline(entries: [entry], policy: policy))
    }

    private func entry() -> GraphWidgetEntry {
        let content = GraphWidgetContent.read()
        let eligibleBlocks = content.randomBlocks.filter {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
        }
        let blocks = showsTasks ? [] : Array(eligibleBlocks.shuffled().prefix(3))
        let selection = showsTasks ? WidgetTaskStatusSelection.read() : nil
        return GraphWidgetEntry(date: .now, content: content, randomBlocks: blocks, selection: selection)
    }
}

private struct GraphWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GraphWidgetEntry
    let showsTasks: Bool

    var body: some View {
        Group {
            if let selection = entry.selection, entry.content.graphId == selection.graphId,
               let task = entry.content.tasks.first(where: {
                   $0.uuid == selection.uuid && $0.statusUuid == selection.statusUuid
               }), let choices = task.statusChoices, !choices.isEmpty {
                statusPicker(for: task, choices: choices, selection: selection)
                    .privacySensitive()
            } else {
                blockList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "logseq://journal"))
    }

    private var blockList: some View {
        let blocks = showsTasks ? entry.content.tasks : entry.randomBlocks
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                if showsTasks {
                    Label("Tasks", systemImage: "checklist")
                } else {
                    Label("Random Blocks", systemImage: "shuffle")
                }
                Spacer()
                if showsTasks, let url = URL(string: "logseq://task") {
                    Link(destination: url) {
                        Image(systemName: "plus")
                            .frame(width: 30, height: 26)
                            .background(.quaternary, in: Capsule())
                    }
                    .accessibilityLabel("Add task")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            if blocks.isEmpty {
                emptyMessage
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            ForEach(blocks) { block in
                HStack(spacing: 8) {
                    if let url = blockURL(block) {
                        Link(destination: url) {
                            Text(block.title)
                                .lineLimit(family == .systemLarge ? 3 : 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let status = block.status {
                        statusControl(for: block, status: status)
                    }
                }
                .font(.subheadline)
                .privacySensitive()
            }
            Spacer(minLength: 0)
        }
    }

    private var emptyMessage: Text {
        if entry.content.graphLocked == true { return Text("Unlock the graph in Logseq.") }
        if entry.content.graphId == nil { return Text("Open a graph in Logseq.") }
        return showsTasks ? Text("No tasks yet.") : Text("No blocks with at least five characters.")
    }

    @ViewBuilder private func statusControl(for block: GraphWidgetContent.Block, status: String) -> some View {
        if let graphId = entry.content.graphId, let current = block.statusUuid,
           let choices = block.statusChoices, choices.contains(where: { $0.uuid != current }) {
            Button(intent: ShowWidgetTaskStatusesIntent(
                graphId: graphId, uuid: block.uuid, statusUuid: current, page: 0
            )) {
                Label(status, systemImage: "chevron.down")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose status for \(block.title), currently \(status)")
        } else {
            Text(status)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
    }

    private func statusPicker(
        for task: GraphWidgetContent.Block,
        choices: [GraphWidgetContent.StatusChoice],
        selection: WidgetTaskStatusSelection
    ) -> some View {
        let lastPage = (choices.count - 1) / 6
        let page = min(selection.page, lastPage)
        let visible = Array(choices.dropFirst(page * 6).prefix(6))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                pickerButton("Cancel", icon: "xmark", selection: selection, page: -1)
            }
            ForEach(0..<((visible.count + 2) / 3), id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(visible.dropFirst(row * 3).prefix(3)) { choice in
                        Button(intent: SetWidgetTaskStatusIntent(
                            graphId: selection.graphId, uuid: task.uuid,
                            expectedStatusUuid: selection.statusUuid, statusUuid: choice.uuid
                        )) {
                            HStack(spacing: 3) {
                                if choice.uuid == selection.statusUuid { Image(systemName: "checkmark") }
                                Text(choice.title).lineLimit(1)
                            }
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(choice.uuid == selection.statusUuid ? .isSelected : [])
                    }
                }
                .foregroundStyle(.primary)
            }
            if lastPage > 0 {
                HStack {
                    if page > 0 {
                        pickerButton("Previous", icon: "chevron.left", selection: selection, page: page - 1)
                    }
                    Spacer()
                    if page < lastPage {
                        pickerButton("Next", icon: "chevron.right", selection: selection, page: page + 1)
                    }
                }
            }
        }
    }

    private func pickerButton(
        _ label: LocalizedStringKey, icon: String, selection: WidgetTaskStatusSelection, page: Int
    ) -> some View {
        Button(intent: ShowWidgetTaskStatusesIntent(
            graphId: selection.graphId, uuid: selection.uuid, statusUuid: selection.statusUuid, page: page
        )) {
            Image(systemName: icon).font(.caption.weight(.semibold)).frame(width: 28, height: 23)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func blockURL(_ block: GraphWidgetContent.Block) -> URL? {
        guard let graphId = entry.content.graphId else { return nil }
        var components = URLComponents()
        components.scheme = "logseq"
        components.host = "graph"
        components.queryItems = [
            URLQueryItem(name: "graph-id", value: graphId),
            URLQueryItem(name: "block-id", value: block.uuid),
            URLQueryItem(name: "widget-action", value: "open-block"),
        ]
        return components.url
    }
}

private struct TaskListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TaskListWidget", provider: GraphWidgetProvider(showsTasks: true)) { entry in
            GraphWidgetView(entry: entry, showsTasks: true)
        }
        .configurationDisplayName("Tasks")
        .description("Add tasks to today's journal and change task status.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct RandomBlocksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RandomBlocksWidget", provider: GraphWidgetProvider(showsTasks: false)) { entry in
            GraphWidgetView(entry: entry, showsTasks: false)
        }
        .configurationDisplayName("Random Blocks")
        .description("Rediscover up to three blocks from your graph.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main struct LogseqWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayJournalWidget()
        CaptureWidget()
        TaskListWidget()
        RandomBlocksWidget()
        RecordingLiveActivityWidget()
        if #available(iOS 18.0, *) {
            QuickAddControl()
            RecordAudioControl()
        }
    }
}
