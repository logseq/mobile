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

private struct LGBottomBarActions: ViewModifier {
    @Environment(\.lgUsesSideCaptureActions) private var usesSideCaptureActions

    func body(content: Content) -> some View {
        if !usesSideCaptureActions {
            content.modifier(LGBottomBarGlass(surface: .trailing))
        }
    }
}

private extension EnvironmentValues {
    @Entry var lgCollectBottomBarGlass = false
}

struct LGBottomBarGlass: ViewModifier {
    enum Surface {
        case capture
        case selection
        case trailing
    }

    enum Position: CaseIterable { case leading, trailing }

    let surface: Surface
    @Environment(\.lgCollectBottomBarGlass) private var collectsGlass

    private var position: Position { surface == .trailing ? .trailing : .leading }

    @ViewBuilder
    func body(content: Content) -> some View {
        if collectsGlass {
            content.anchorPreference(key: LGBottomBarGlassBounds.self, value: .bounds) { anchor in
                [position: anchor]
            }
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(surface != .capture), in: .capsule)
        } else if surface == .capture {
            content.background(.regularMaterial, in: Capsule())
        } else {
            content.modifier(LGLiquidGlassSurface(shape: .capsule))
        }
    }
}

private struct LGBottomBarGlassBounds: PreferenceKey {
    static let defaultValue: [LGBottomBarGlass.Position: Anchor<CGRect>] = [:]

    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct LGBottomBarGlassLayer: ViewModifier {
    let animation: Animation?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                content.environment(\.lgCollectBottomBarGlass, true)
            }
            .backgroundPreferenceValue(LGBottomBarGlassBounds.self) { anchors in
                GeometryReader { geometry in
                    // The model replaces the controls. Their glass stays mounted
                    // and animates to the new bounds behind the incoming controls.
                    GlassEffectContainer(spacing: 0) {
                        ForEach(LGBottomBarGlass.Position.allCases, id: \.self) { position in
                            if let anchor = anchors[position] {
                                let frame = geometry[anchor]
                                Color.clear
                                    .frame(width: frame.width, height: frame.height)
                                    .glassEffect(.regular, in: .capsule)
                                    .position(x: frame.midX, y: frame.midY)
                                    .animation(animation, value: frame)
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else {
            content
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
