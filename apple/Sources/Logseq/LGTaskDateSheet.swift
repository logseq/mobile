#if os(iOS)
import LUIAppleBackend
import SwiftUI

@MainActor
enum LGTaskDateSheetExtension {
    static let identifier = "native-task-date-sheet"
    static let fingerprint = "lui-extension-v1|22:native-task-date-sheet|profiles:ios/swiftui|standard-children:0|children:|properties:7:payload:string:required:none|events:5:clear[],6:choose[5:value:string:required],6:submit[5:value:string:required],7:dismiss[]"

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

private struct LGTaskDateSheetState: Decodable {
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

    var selection: Date? {
        value.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

private struct LGTaskDatePresentation: View {
    let context: LUIAppleExtensionViewContext
    let state: LGTaskDateSheetState
    @State private var presented = true

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .sheet(isPresented: $presented, onDismiss: {
                try? context.emit(name: "dismiss", values: [:])
            }) {
                LGTaskDateSheet(context: context, state: state)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.hidden)
                    .presentationContentInteraction(.scrolls)
                    .presentationCornerRadius(28)
                    .presentationBackground(.regularMaterial)
            }
    }
}

private struct LGTaskDateSheet: View {
    let context: LUIAppleExtensionViewContext
    let state: LGTaskDateSheetState
    @Environment(\.locale) private var locale
    @Environment(\.luiSemanticColors) private var colors
    @ScaledMetric(relativeTo: .body) private var dayHeight: CGFloat = 37
    @FocusState private var editingInput: Bool
    @State private var input = ""
    @State private var displayedDate: Date?

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = locale
        return calendar
    }

    private var month: Date { displayedDate ?? state.selection ?? Date() }
    private var accent: Color { colors["primary"] ?? LogseqThemePolicy.accent }
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
                    .foregroundStyle(accent)
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
                        monthHeader
                        monthGrid
                    }
                    .padding(.horizontal, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .disabled(!enabled)
            } else {
                Spacer()
                if state.waiting {
                    ProgressView().accessibilityIdentifier("task-dates.loading")
                }
                Spacer()
            }

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
        .tint(accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.task-dates")
    }

    private var monthHeader: some View {
        HStack(spacing: 0) {
            Text(monthTitle)
                .font(.headline)
                .padding(.leading, 8)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("task-dates.month")
            Spacer()
            monthButton("chevron.backward", label: "Previous month", id: "previous") { moveMonth(-1) }
            monthButton("dot.circle", label: "Today", id: "today") { displayedDate = Date() }
            monthButton("chevron.forward", label: "Next month", id: "next") { moveMonth(1) }
        }
    }

    private func monthButton(_ icon: String, label: LocalizedStringKey, id: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("task-dates.month." + id)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(month, equalTo: Date(), toGranularity: .year) ? "LLLL" : "yLLLL")
        return formatter.string(from: month)
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
            ForEach(0..<7) { offset in
                Text(calendar.shortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + offset) % 7])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, minHeight: 25)
                    .accessibilityHidden(true)
            }
            ForEach(days, id: \.self) { day in dayButton(day) }
        }
    }

    private var days: [Date] {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start else { return [] }
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: start) }
    }

    private func dayButton(_ day: Date) -> some View {
        let number = calendar.component(.day, from: day)
        let selected = state.selection.map { calendar.isDate(day, inSameDayAs: $0) } ?? false
        let today = calendar.isDateInToday(day)
        let currentMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        return Button { choose(day) } label: {
            Text(number, format: .number)
                .font(.body.monospacedDigit())
                .foregroundStyle(selected || today ? accent : (currentMonth ? Color.primary : Color.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, minHeight: dayHeight)
                .background((selected || today) ? accent.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day().year().locale(locale)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("task-dates.day.\(calendar.component(.year, from: day))-\(calendar.component(.month, from: day))-\(number)")
    }

    private func moveMonth(_ direction: Int) {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start else { return }
        displayedDate = calendar.date(byAdding: .month, value: direction, to: start)
    }

    private func choose(_ day: Date) {
        let time = state.selection.map { calendar.dateComponents([.hour, .minute, .second], from: $0) }
        let date = calendar.date(bySettingHour: time?.hour ?? 0, minute: time?.minute ?? 0,
                                 second: time?.second ?? 0, of: day) ?? day
        editingInput = false
        let millis = Int((date.timeIntervalSince1970 * 1000).rounded())
        try? context.emit(name: "choose", values: ["value": .string(String(millis))])
    }

    private func submit() {
        guard canSubmit else { return }
        try? context.emit(name: "submit", values: ["value": .string(input)])
    }
}
#endif
