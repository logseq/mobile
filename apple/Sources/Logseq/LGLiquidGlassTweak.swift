import LUIAppleBackend
import SwiftUI

@MainActor
enum LGLiquidGlassTweak {
    static let identifier = "liquid-glass"
    static let fingerprint =
        "lui-tweak-v1|12:liquid-glass|profiles:ios/swiftui|properties:5:shape:string:required:none"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.registerTweak(
            LUIAppleTweak(
                identifier: identifier,
                fingerprint: fingerprint,
                properties: [
                    .init(name: "shape", kind: .string, isRequired: true),
                ]
            ) { content, context in
                let shapeName: String
                if case let .string(value) = context.property("shape") {
                    shapeName = value
                } else {
                    shapeName = ""
                }
                let shape: LGLiquidGlassSurface.Shape
                switch shapeName {
                case "bottom-capture":
                    return AnyView(content.modifier(LGBottomBarGlass(surface: .capture)))
                case "bottom-actions":
                    return AnyView(content.modifier(LGBottomBarActions()))
                case "bottom-search":
                    return AnyView(content.modifier(LGBottomBarGlass(surface: .trailing)))
                case "circle":
                    shape = .circle
                case "container":
                    shape = .container
                case "rounded-rectangle":
                    shape = .roundedRectangle
                default:
                    shape = .capsule
                }
                if shape == .capsule {
                    return AnyView(
                        content
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(LGLiquidGlassSurface(shape: shape))
                    )
                }
                return AnyView(content.modifier(LGLiquidGlassSurface(shape: shape)))
            }
        )
    }
}

extension EnvironmentValues {
    @Entry var lgUsesSideCaptureActions = false
}

@MainActor
struct LGBottomChromeSwitch: View {
    let context: LUIAppleExtensionViewContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(LUIAppleExtension(
            identifier: "bottom-chrome-switch",
            fingerprint: "lui-extension-v1|20:bottom-chrome-switch|profiles:ios/swiftui|standard-children:1|children:|properties:16:selection-active:bool:required:none|events:",
            acceptsStandardChildren: true,
            properties: [.init(name: "selection-active", kind: .bool, isRequired: true)]
        ) { AnyView(LGBottomChromeSwitch(context: $0)) })
    }

    var body: some View {
        let _ = context.revision
        let selectionActive = context.property("selection-active") == .bool(true)
        let children = context.childIDs
        ZStack(alignment: .bottom) {
            if children.count == 2 {
                if selectionActive {
                    chrome(children[1])
                } else {
                    chrome(children[0])
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectionActive)
    }

    private func chrome(_ id: Int) -> some View {
        // Fade each capsule with its own icons, with a brief overlap on exchange.
        context.content(for: id)
            .compositingGroup()
            .transition(reduceMotion ? .identity : .asymmetric(
                insertion: .opacity.animation(.easeOut(duration: 0.12).delay(0.06)),
                removal: .opacity.animation(.easeIn(duration: 0.12))
            ))
    }
}

private struct LGBottomBarActions: ViewModifier {
    @Environment(\.lgUsesSideCaptureActions) private var usesSideCaptureActions

    func body(content: Content) -> some View {
        if !usesSideCaptureActions {
            content.modifier(LGBottomBarGlass(surface: .trailing))
        }
    }
}

struct LGBottomBarGlass: ViewModifier {
    enum Surface {
        case capture
        case selection
        case trailing
    }

    let surface: Surface

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(surface != .capture), in: .capsule)
        } else if surface == .capture {
            content.background(.regularMaterial, in: Capsule())
        } else {
            content.modifier(LGLiquidGlassSurface(shape: .capsule))
        }
    }
}

struct LGLiquidGlassSurface: ViewModifier {
    enum Shape {
        case capsule
        case circle
        case container
        case roundedRectangle
    }

    let shape: Shape

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if shape == .circle {
                content.glassEffect(.regular.interactive(), in: .circle)
            } else if shape == .roundedRectangle {
                content.glassEffect(
                    .regular,
                    in: .rect(cornerRadius: 24)
                )
            } else if shape == .container {
                content.glassEffect(
                    .regular,
                    in: .rect(cornerRadius: 28)
                )
            } else {
                content.glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            if shape == .circle {
                content.background(.ultraThinMaterial, in: Circle())
            } else if shape == .roundedRectangle {
                content.background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
            } else if shape == .container {
                content.background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
            } else {
                content.background(.ultraThinMaterial, in: Capsule())
            }
        }
    }
}
