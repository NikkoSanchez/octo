import AppKit
import SwiftUI
import OctoCore

/// Settings → Appearance: a menu for quick keyboard choice, then preview cards
/// grouped into Automatic, Light and Dark so the two families are easy to compare.
struct ThemeGallery: View {
    @Binding var selection: AppTheme
    private static let light = AppTheme.allCases.filter { $0.isDark == false }
    private static let dark = AppTheme.allCases.filter { $0.isDark == true }
    private let columns = [GridItem(.adaptive(minimum: 176), spacing: 12)]

    var body: some View {
        Section {
            Picker("Theme", selection: $selection) {
                Text(AppTheme.system.title).tag(AppTheme.system)
                Section("Light") { ForEach(Self.light) { Text($0.title).tag($0) } }
                Section("Dark") { ForEach(Self.dark) { Text($0.title).tag($0) } }
            }
            ThemeCard(theme: .system, selected: selection == .system) { selection = .system }
                .frame(maxWidth: 260, alignment: .leading)
                .padding(.vertical, 4)
        } header: { Text("Color theme") } footer: {
            Text("Applies immediately to Octo, code previews, and terminal colors. macOS System follows your Mac's light or dark appearance and uses your Ghostty configuration where supported. Neovim uses its own installed theme.")
                .font(.system(size: 12)).foregroundStyle(selection.secondary)
        }
        group("Light", Self.light)
        group("Dark", Self.dark)
    }

    private func group(_ title: String, _ themes: [AppTheme]) -> some View {
        Section(title) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(themes) { theme in
                    ThemeCard(theme: theme, selected: selection == theme) { selection = theme }
                }
            }.padding(.vertical, 6)
        }
    }
}

private struct ThemeCard: View {
    let theme: AppTheme
    let selected: Bool
    let action: () -> Void
    @Environment(\.octoTheme) private var current

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                    .frame(height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
                HStack(spacing: 6) {
                    Text(theme.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(current.accent) }
                }
            }
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? current.accent : current.hairline, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityValue(theme.isDark.map { $0 ? "Dark" : "Light" } ?? "Follows macOS")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var preview: some View {
        if let palette = theme.palette, let syntax = theme.syntax {
            let c = { (hex: String) in Color(nsColor: NSColor(themeHex: hex)) }
            let token = { (text: String, role: SyntaxRole) in
                Text(text).foregroundColor(c(syntax.color(role))).italic(syntax.italic.contains(role))
            }
            HStack(spacing: 0) {
                // The sidebar on the panel colour: thread rows drawn as the app draws them,
                // the first selected with the theme's list selection and selection text.
                VStack(alignment: .leading, spacing: 3) {
                    previewRow(palette, selected: true)
                    previewRow(palette, selected: false)
                    previewRow(palette, selected: false)
                    Spacer(minLength: 0)
                }
                .padding(4).frame(width: 52).frame(maxHeight: .infinity, alignment: .top).background(c(palette.mantle))
                VStack(alignment: .leading, spacing: 4) {
                    (token("let ", .keyword) + Text("idea").foregroundColor(c(palette.text))
                        + token(" = ", .operatorSymbol) + token("\"Octo\"", .string))
                    (token("run", .function) + token("(", .punctuation) + token("42", .number) + token(")", .punctuation))
                    token("// \(theme.isDark == true ? "dark" : "light")", .comment)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        ForEach([palette.red, palette.yellow, palette.green, palette.blue, palette.accent], id: \.self) {
                            Circle().fill(c($0)).frame(width: 7, height: 7)
                        }
                    }
                }
                .font(.system(size: 10, design: .monospaced)).lineLimit(1)
                .padding(7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(c(palette.base))
            }
        } else {
            // System: native light and dark halves with the Mac's accent, which also fills selected rows.
            HStack(spacing: 0) {
                ForEach([NSAppearance.Name.aqua, .darkAqua], id: \.self) { name in
                    SystemHalf(appearance: name)
                }
            }
        }
    }
}

private extension ThemeCard {
    /// A miniature thread row: avatar dot, title and preview lines.
    func previewRow(_ palette: ThemePalette, selected: Bool) -> some View {
        let c = { (hex: String) in Color(nsColor: NSColor(themeHex: hex)) }
        let title = selected ? c(palette.listSelectionText) : c(palette.text).opacity(0.75)
        let detail = selected ? c(palette.listSelectionText).opacity(0.6) : c(palette.secondary).opacity(0.55)
        return HStack(spacing: 4) {
            Circle().fill(c(palette.overlay0)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Capsule().fill(title).frame(width: 24, height: 3)
                Capsule().fill(detail).frame(width: 18, height: 3)
            }
        }
        .padding(.horizontal, 3).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? c(palette.listSelection) : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(c(palette.activeBorder), lineWidth: 0.75).opacity(selected ? 1 : 0))
    }
}

private struct SystemHalf: View {
    let appearance: NSAppearance.Name
    var body: some View {
        let dark = appearance == .darkAqua
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(Color.white).frame(width: 30, height: 3).padding(4)
                .frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
            Capsule().fill((dark ? Color.white : Color.black).opacity(0.25)).frame(width: 44, height: 4)
            Capsule().fill((dark ? Color.white : Color.black).opacity(0.15)).frame(width: 36, height: 4)
            Spacer(minLength: 0)
            Text("Aa").font(.system(size: 13, weight: .semibold)).foregroundStyle(dark ? Color.white : Color.black)
        }
        .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dark ? Color(white: 0.14) : Color(white: 0.97))
    }
}
