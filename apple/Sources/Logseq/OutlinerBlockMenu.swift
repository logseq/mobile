#if os(iOS)
import SwiftUI
import UIKit

@MainActor enum OutlinerBlockMenuItem {
    case action(title: String, image: UIImage?, destructive: Bool, perform: () -> Void)
    case submenu(title: String, image: UIImage?, items: [Self])

    var native: UIMenuElement {
        switch self {
        case let .action(title, image, destructive, perform):
            UIAction(title: title, image: image, attributes: destructive ? .destructive : []) { _ in perform() }
        case let .submenu(title, image, items):
            UIMenu(title: title, image: image, children: items.map(\.native))
        }
    }
}

@MainActor struct OutlinerBlockMenuSheet: View {
    let reactions: [OutlinerRowPayload.ReactionChoice]
    let groups: [[OutlinerBlockMenuItem]]
    let moreLabel: String
    let semanticColors: [String: Color]
    let onChoose: (@escaping () -> Void) -> Void
    let onReaction: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.logseqDarkTheme) private var darkTheme

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(reactions, id: \.id) { choice in
                    shortcut(selected: choice.selected, label: choice.name, id: "reaction.quick." + choice.id,
                             action: { onReaction("reaction:" + choice.id) }) {
                        Text(verbatim: choice.emoji).font(.system(size: 22))
                    }
                }
                shortcut(label: moreLabel, id: "reaction.more", action: { onReaction("reaction") }) {
                    Image(systemName: "face.smiling").font(.system(size: 21))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            Divider().padding(.horizontal, 16)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(groups.indices, id: \.self) { group in
                        if group > 0 { Divider().padding(.vertical, 4) }
                        ForEach(groups[group].indices, id: \.self) { index in
                            actionRow(groups[group][index])
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .presentationDetents([.fraction(0.66), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(LogseqThemePolicy.sheetBackground(isDark: colorScheme == .dark, darkTheme: darkTheme))
    }

    private func shortcut<Icon: View>(selected: Bool = false, label: String, id: String,
                                      action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            icon()
                .frame(width: 44, height: 44)
                .background(
                    selected ? semanticColors["task-tab-selected-background"] ?? Color.accentColor.opacity(0.2)
                             : semanticColors["task-tab-background"] ?? Color.primary.opacity(0.08),
                    in: Circle()
                )
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private func actionRow(_ item: OutlinerBlockMenuItem) -> some View {
        switch item {
        case let .action(title, image, destructive, perform):
            Button(role: destructive ? .destructive : nil) { onChoose(perform) } label: {
                rowLabel(title, image: image).foregroundStyle(destructive ? Color.red : Color.primary)
            }
            .buttonStyle(.plain)
        case let .submenu(title, image, items):
            Menu {
                ForEach(items.indices, id: \.self) { index in
                    if case let .action(title, image, destructive, perform) = items[index] {
                        Button(role: destructive ? .destructive : nil) { onChoose(perform) } label: {
                            Text(verbatim: title)
                            if let image { Image(uiImage: image) }
                        }
                    }
                }
            } label: {
                rowLabel(title, image: image, submenu: true).foregroundStyle(.primary)
            }
            .menuOrder(.fixed)
            .tint(.primary)
        }
    }

    private func rowLabel(_ title: String, image: UIImage?, submenu: Bool = false) -> some View {
        HStack(spacing: 10) {
            Group {
                if let image {
                    Image(uiImage: image).renderingMode(.template)
                        .resizable().scaledToFit().frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 26)
            Text(verbatim: title)
            Spacer(minLength: 8)
            if submenu {
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
#endif
