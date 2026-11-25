#if os(iOS)
import LUIAppleBackend
import LogseqModel
import Observation
import SwiftUI
import UIKit

@MainActor
enum LGTaskDateSheetExtension {
    static let identifier = "native-task-date-sheet"
    static let fingerprint = "lui-extension-v1|22:native-task-date-sheet|profiles:android/kotlin,ios/swiftui|standard-children:0|children:|properties:7:payload:string:required:none|events:5:clear[],6:choose[5:value:string:required],6:submit[5:value:string:required],7:dismiss[]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(LUIAppleExtension(
            identifier: identifier,
            fingerprint: fingerprint,
            properties: [.init(name: "payload", kind: .string, isRequired: true)],
            events: [
                .init(name: "clear", fields: []),
                .init(name: "choose", fields: [.init(name: "value", kind: .string, isRequired: true)]),
                .init(name: "submit", fields: [.init(name: "value", kind: .string, isRequired: true)]),
                .init(name: "dismiss", fields: [])
            ]
        ) { context in
            guard case let .string(payload) = context.property("payload"),
                  let state = try? JSONDecoder().decode(LGTaskDateSheetState.self, from: Data(payload.utf8))
            else { return AnyView(EmptyView()) }
            return AnyView(LGTaskDatePresentation(context: context, state: state))
        })
    }
}

struct LGTaskDateSheetState: Decodable, Equatable {
    struct RepeatOptions: Decodable, Equatable {
        struct Choice: Decodable, Equatable, Identifiable {
            let id: String
            let label: String
        }

        let title: String
        let selection: String
        let value: String
        let choices: [Choice]
    }

    let title: String
    let clearTitle: String
    let submitTitle: String
    let mixedTitle: String
    let value: Int?
    let ready: Bool
    let waiting: Bool
    let canClear: Bool
    let mixed: Bool
    let error: String?
    let repeatOptions: RepeatOptions?

    var selection: Date? {
        value.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

struct LGTaskDateSheetDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        // Allow a six-week month, the search field, and the task date actions.
        min(560, context.maxDetentValue)
    }
}

@MainActor @Observable
final class LGTaskDateSheetRequest: Identifiable {
    let id = UUID()
    let context: LUIAppleExtensionViewContext
    var state: LGTaskDateSheetState

    init(context: LUIAppleExtensionViewContext, state: LGTaskDateSheetState) {
        self.context = context
        self.state = state
    }
}

private struct LGTaskDatePresentation: View {
    let context: LUIAppleExtensionViewContext
    let state: LGTaskDateSheetState
    @Environment(\.lgPlatformPresentation) private var coordinator
    @State private var request: LGTaskDateSheetRequest?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear {
                let request = LGTaskDateSheetRequest(context: context, state: state)
                self.request = request
                coordinator?.presentTaskDateSheet(request)
            }
            .onChange(of: state) { _, state in request?.state = state }
            .onDisappear {
                if let request { coordinator?.dismissTaskDateSheet(request) }
            }
    }
}

struct LGTaskDateSheet: View {
    let context: LUIAppleExtensionViewContext
    let state: LGTaskDateSheetState
    @Environment(\.calendar) private var calendar
    @FocusState private var editingInput: Bool
    @State private var input = ""
    private var enabled: Bool { state.ready && !state.waiting }
    private var canSubmit: Bool { enabled && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(state.title, text: $input)
                    .focused($editingInput)
                    .submitLabel(.done)
                    .onSubmit(submit)
                    .accessibilityIdentifier("task-dates.input")
                if !input.isEmpty {
                    Button(action: submit) {
                        Image(systemName: "checkmark").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(!canSubmit)
                    .accessibilityLabel(state.submitTitle)
                    .accessibilityIdentifier("task-dates.submit")
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(minHeight: 50)
            .disabled(!enabled)

            Divider()

            if state.ready {
                ScrollView {
                    VStack(spacing: 0) {
                        LGTaskCalendar(selection: state.selection, onSelect: choose)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .disabled(!enabled)
                        feedback
                        dateActions
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            } else {
                Spacer()
                if state.waiting {
                    ProgressView().accessibilityIdentifier("task-dates.loading")
                }
                Spacer()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.task-dates")
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = state.error {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("task-dates.error")
        } else if state.mixed {
            Text(state.mixedTitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var dateActions: some View {
        if let options = state.repeatOptions {
            Menu {
                ForEach(options.choices) { choice in
                    Button {
                        editingInput = false
                        try? context.emit(name: "choose", values: ["value": .string("repeat:\(choice.id)")])
                    } label: {
                        if choice.id == options.selection {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                }
            } label: {
                HStack {
                    Label(options.title, systemImage: "repeat")
                    Spacer()
                    Text(options.value)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
            }
            .foregroundStyle(.primary)
            .disabled(!enabled)
            .accessibilityIdentifier("task-dates.repeat")
            .padding(.horizontal, 12)
        }

        Button {
            editingInput = false
            try? context.emit(name: "clear", values: [:])
        } label: {
            Text(state.clearTitle)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled || !state.canClear)
        .opacity(enabled && state.canClear ? 1 : 0.45)
        .accessibilityIdentifier("task-dates.clear")
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func choose(_ day: Date) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.era, .year, .month, .day], from: day)
        guard parts.era == 1, let year = parts.year, let month = parts.month, let date = parts.day else { return }
        editingInput = false
        try? context.emit(name: "choose", values: ["value": .string(String(year * 10000 + month * 100 + date))])
    }

    private func submit() {
        guard canSubmit else { return }
        try? context.emit(name: "submit", values: ["value": .string(input)])
    }
}

private struct LGTaskCalendar: UIViewRepresentable {
    let selection: Date?
    let onSelect: (Date) -> Void
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = calendar
        view.locale = locale
        view.timeZone = calendar.timeZone
        view.tintColor = UIColor(LogseqThemePolicy.accent)
        view.wantsDateDecorations = false
        view.accessibilityIdentifier = "task-dates.calendar"
        view.selectionBehavior = context.coordinator.selection
        view.visibleDateComponents = dateComponents(selection ?? Date())
        return view
    }

    func updateUIView(_ view: UICalendarView, context: Context) {
        context.coordinator.onSelect = onSelect
        view.isUserInteractionEnabled = isEnabled
        let selected = selection.map(dateComponents)
        if context.coordinator.selection.selectedDate != selected {
            context.coordinator.selection.selectedDate = selected
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }

    private func dateComponents(_ date: Date) -> DateComponents {
        calendar.dateComponents([.calendar, .era, .year, .month, .day], from: date)
    }

    final class Coordinator: NSObject, UICalendarSelectionSingleDateDelegate {
        lazy var selection = UICalendarSelectionSingleDate(delegate: self)
        var onSelect: ((Date) -> Void)?

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate components: DateComponents?) {
            if let date = components?.date { onSelect?(date) }
        }
    }
}
#endif
