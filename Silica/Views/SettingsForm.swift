import SwiftUI

// Settings panes are built from these instead of `Form` with `.formStyle(.grouped)`,
// which looks the same but never grows wider than about 640 pt, so a wider window
// only added empty margins.

/// A pane's scrolling column of groups, filling the window's width.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A rounded box of rows split by hairlines, with an optional title above it and a
/// note below it, like a grouped Form section.
struct SettingsGroup<Content: View, Footer: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: NSFont.systemFontSize, weight: .semibold))
                    .padding(.horizontal, 10)
            }

            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.horizontal, 10)
                        }
                        row
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.045)))

            footer
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
    }
}

extension SettingsGroup where Footer == EmptyView {
    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, footer: { EmptyView() })
    }
}

/// A row with its label on the left and its control pushed to the right edge.
struct SettingsRow<Label: View, Control: View>: View {
    @ViewBuilder var label: Label
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                label
            }
            Spacer(minLength: 0)
            control
        }
    }
}

extension SettingsRow where Label == Text {
    init(_ title: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        self.label = Text(title)
        self.control = control()
    }
}

/// A switch row, as Toggle draws in a grouped Form.
struct SettingsToggle: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A pop-up menu row, as Picker draws in a grouped Form.
struct SettingsPicker<Value: Hashable, Options: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    @ViewBuilder var options: Options

    init(_ title: LocalizedStringKey, selection: Binding<Value>, @ViewBuilder options: () -> Options) {
        self.title = title
        self._selection = selection
        self.options = options()
    }

    var body: some View {
        SettingsRow(title) {
            Picker(title, selection: $selection) { options }
                .labelsHidden()
                .fixedSize()
        }
    }
}

/// The Settings window's two backgrounds: a near-white sidebar beside a light gray
/// detail area (and the dark-mode counterparts), since the system window and control
/// background colors both come out white.
enum SettingsColors {
    static let sidebar = adaptive(light: 0.975, dark: 0.15)
    static let detail = adaptive(light: 0.945, dark: 0.19)

    private static func adaptive(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }
}
