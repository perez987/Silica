import AppKit
import SwiftUI

/// AppKit frosted background. Unlike SwiftUI materials, this exposes the full set of
/// `NSVisualEffectView` materials and can stay frosted while the window is inactive.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State

    init(
        _ material: NSVisualEffectView.Material = .menu,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

struct WindowBackground: View {
    var material: NSVisualEffectView.Material = .menu
    private var settings: EditorSettings { .shared }

    var body: some View {
        if settings.windowStyle == .glass {
            VisualEffectView(material)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}
