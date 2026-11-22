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
    struct StatusAppearance: Decodable {
        let icon: String
        let light: String
        let dark: String

        func color(in colorScheme: ColorScheme) -> Color {
            let hex = colorScheme == .dark ? dark : light
            guard hex.hasPrefix("#"), let value = UInt64(hex.dropFirst(), radix: 16),
                  hex.count == 7 || hex.count == 9 else { return .primary }
            let rgb = hex.count == 9 ? value >> 8 : value
            return Color(red: Double((rgb >> 16) & 255) / 255,
                         green: Double((rgb >> 8) & 255) / 255,
                         blue: Double(rgb & 255) / 255,
                         opacity: hex.count == 9 ? Double(value & 255) / 255 : 1)
        }
    }

    struct StatusChoice: Decodable, Identifiable {
        let uuid: String
        let title: String
        var appearance: StatusAppearance? = nil
        var id: String { uuid }
    }

    struct Block: Decodable, Identifiable {
        let uuid: String
        let title: String
        let status: String?
        var statusUuid: String? = nil
        var statusAppearance: StatusAppearance? = nil
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
        let todo = GraphWidgetContent.StatusAppearance(icon: "app:task-todo", light: "#858585", dark: "#7E7E7E")
        let doing = GraphWidgetContent.StatusAppearance(icon: "app:task-doing", light: "#EBBC00", dark: "#D9B94C")
        let task = GraphWidgetContent.Block(uuid: "task", title: "Review project notes", status: "Todo",
            statusUuid: "todo", statusAppearance: todo,
            statusChoices: [.init(uuid: "todo", title: "Todo", appearance: todo),
                            .init(uuid: "doing", title: "Doing", appearance: doing)])
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
        let blocks = showsTasks ? [] : Array(eligibleBlocks.shuffled().prefix(4))
        let selection = showsTasks ? WidgetTaskStatusSelection.read() : nil
        return GraphWidgetEntry(date: .now, content: content, randomBlocks: blocks, selection: selection)
    }
}

private struct GraphWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GraphWidgetEntry
    let showsTasks: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var selectedTask: (WidgetTaskStatusSelection, GraphWidgetContent.Block, Int)? {
        guard let selection = entry.selection, entry.content.graphId == selection.graphId,
              let index = entry.content.tasks.firstIndex(where: {
                  $0.uuid == selection.uuid && $0.statusUuid == selection.statusUuid
              }) else { return nil }
        return (selection, entry.content.tasks[index], index)
    }

    var body: some View {
        blockList
            .accessibilityHidden(selectedTask != nil)
            .allowsHitTesting(selectedTask == nil)
            .overlay(alignment: .topLeading) {
                if let (selection, task, index) = selectedTask,
                   let choices = task.statusChoices, !choices.isEmpty {
                    statusPopup(for: task, choices: choices, selection: selection, row: index)
                        .privacySensitive()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(selectedTask == nil ? URL(string: "logseq://journal") : nil)
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
                } else if !showsTasks, entry.content.graphId != nil {
                    Button(intent: RefreshRandomBlocksWidgetIntent()) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 30, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh random blocks")
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
                HStack(spacing: 5) {
                    if let status = block.status {
                        statusControl(for: block, status: status)
                    }
                    if let url = blockURL(block) {
                        Link(destination: url) {
                            Text(block.title)
                                .lineLimit(family == .systemLarge ? 3 : 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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

    private func statusIcon(_ appearance: GraphWidgetContent.StatusAppearance?) -> some View {
        let asset = (appearance?.icon ?? "app:task-todo")
            .replacingOccurrences(of: "app:", with: "").replacingOccurrences(of: "-", with: "_")
        return Image(asset).renderingMode(.template).resizable().scaledToFit()
            .frame(width: 20, height: 20)
            .foregroundStyle(appearance?.color(in: colorScheme) ?? .secondary)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func statusControl(for block: GraphWidgetContent.Block, status: String) -> some View {
        if let graphId = entry.content.graphId, let current = block.statusUuid,
           let choices = block.statusChoices, choices.contains(where: { $0.uuid != current }) {
            Button(intent: ShowWidgetTaskStatusesIntent(
                graphId: graphId, uuid: block.uuid, statusUuid: current, page: 0
            )) {
                statusIcon(block.statusAppearance)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose status for \(block.title), currently \(status)")
        } else {
            statusIcon(block.statusAppearance).frame(width: 32, height: 28)
                .accessibilityLabel(status)
        }
    }

    private func statusPopup(
        for task: GraphWidgetContent.Block,
        choices: [GraphWidgetContent.StatusChoice],
        selection: WidgetTaskStatusSelection,
        row: Int
    ) -> some View {
        let pageSize = choices.count <= 6 ? 6 : 5
        let lastPage = (choices.count - 1) / pageSize
        let page = min(selection.page, lastPage)
        let visible = Array(choices.dropFirst(page * pageSize).prefix(pageSize))
        let popupHeight = CGFloat(visible.count + (lastPage > 0 ? 1 : 0)) * 20 + 8
        return GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Button(intent: pickerIntent(selection, page: -1)) {
                    Color.primary.opacity(0.04).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss task status menu")

                VStack(spacing: 0) {
                    ForEach(visible) { choice in
                        Button(intent: SetWidgetTaskStatusIntent(
                            graphId: selection.graphId, uuid: task.uuid,
                            expectedStatusUuid: selection.statusUuid, statusUuid: choice.uuid
                        )) {
                            HStack(spacing: 8) {
                                statusIcon(choice.appearance)
                                Text(choice.title).lineLimit(1)
                                Spacer(minLength: 3)
                                if choice.uuid == selection.statusUuid {
                                    Image(systemName: "checkmark").font(.caption2.weight(.semibold))
                                }
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 20)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(choice.uuid == selection.statusUuid ? .isSelected : [])
                    }
                    if lastPage > 0 {
                        Divider()
                        HStack {
                            if page > 0 {
                                pickerButton("Previous", icon: "chevron.left", selection: selection, page: page - 1)
                            }
                            Spacer()
                            if page < lastPage {
                                pickerButton("Next", icon: "chevron.right", selection: selection, page: page + 1)
                            }
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 19)
                    }
                }
                .font(.caption)
                .padding(.vertical, 4)
                .frame(width: min(geometry.size.width, 168))
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(colorScheme == .dark ? Color(white: 0.16) : .white)
                        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                }
                .offset(y: min(CGFloat(52 + row * 33), max(0, geometry.size.height - popupHeight)))
            }
        }
    }

    private func pickerIntent(_ selection: WidgetTaskStatusSelection, page: Int) -> ShowWidgetTaskStatusesIntent {
        ShowWidgetTaskStatusesIntent(
            graphId: selection.graphId, uuid: selection.uuid, statusUuid: selection.statusUuid, page: page
        )
    }

    private func pickerButton(
        _ label: LocalizedStringKey, icon: String, selection: WidgetTaskStatusSelection, page: Int
    ) -> some View {
        Button(intent: pickerIntent(selection, page: page)) {
            Image(systemName: icon).font(.caption2.weight(.semibold))
                .frame(width: 36, height: 19)
                .contentShape(Rectangle())
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
        .description("Rediscover up to four blocks from your graph.")
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
