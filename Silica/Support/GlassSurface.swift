import SwiftUI

extension View {
    func glassSurface(_ isOn: Bool = true, in shape: some Shape) -> some View {
        modifier(GlassSurface(isOn: isOn, shape: shape))
    }

    func glassButtonStyle(prominent: Bool = false) -> some View {
        modifier(GlassButtonStyle(isProminent: prominent))
    }

    @ViewBuilder
    func workspaceCard() -> some View {
        if #available(macOS 26.0, *) {
            let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(WorkspaceLayout.cardCornerRadius)))
            clipShape(shape).glassSurface(in: shape)
        } else {
            let shape = RoundedRectangle(cornerRadius: WorkspaceLayout.cardCornerRadius, style: .continuous)
            clipShape(shape).glassSurface(in: shape)
        }
    }

    @ViewBuilder
    func glassContainer(spacing: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    @ViewBuilder
    func softVerticalScrollEdges() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            self
        }
    }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let isOn: Bool
    let shape: S
    private var settings: EditorSettings { .shared }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), settings.usesGlassEffect {
            content.glassEffect(isOn ? .regular : .identity, in: shape)
        } else {
            content
                .background {
                    if isOn {
                        shape
                            .fill(Color(nsColor: .textBackgroundColor))
                            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    }
                }
                .overlay {
                    if isOn {
                        shape
                            .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

private struct GlassButtonStyle: ViewModifier {
    let isProminent: Bool
    private var settings: EditorSettings { .shared }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), settings.usesGlassEffect {
            if isProminent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
