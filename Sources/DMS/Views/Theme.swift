import AppKit
import SwiftUI

/// Dunkles Design mit Orange als Akzent: Karten mit weichem Verlauf, dünne große Zahlen, Symbole in Kacheln.
enum Theme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let sidebar = Color(red: 0.075, green: 0.075, blue: 0.08)
    static let cardTop = Color(red: 0.115, green: 0.115, blue: 0.12)
    static let cardBottom = Color(red: 0.08, green: 0.08, blue: 0.085)
    static let stroke = Color.white.opacity(0.07)

    static let accent = Color(red: 1.0, green: 0.36, blue: 0.13)        // #FF5C21
    static let accentLight = Color(red: 1.0, green: 0.56, blue: 0.27)   // #FF8F45
    static let accentDeep = Color(red: 0.62, green: 0.18, blue: 0.05)   // #9E2E0D
    static let positive = Color(red: 0.35, green: 0.85, blue: 0.5)

    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.32)
    static let track = Color.white.opacity(0.09)

    /// Abstufungen für Diagramme, vom kräftigen Orange zu dunklem Grau.
    static let palette: [Color] = [
        accent,
        accentLight,
        Color(red: 0.78, green: 0.26, blue: 0.08),
        Color(red: 1.0, green: 0.74, blue: 0.52),
        Color(red: 0.45, green: 0.45, blue: 0.47),
        Color(red: 0.3, green: 0.3, blue: 0.32),
    ]

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentDeep, accent, accentLight], startPoint: .leading, endPoint: .trailing)
    }
}

/// Karte im Stil des Dashboards.
struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var padding: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }
}

extension View {
    /// Klickbarer Bereich im Dashboard: Handzeiger, leichtes Aufhellen, Sprung beim Klick.
    func drillDown(_ help: String, action: @escaping () -> Void) -> some View {
        modifier(DrillDown(help: help, action: action))
    }

    func cardBackground(cornerRadius: CGFloat = 22) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [Theme.cardTop, Theme.cardBottom], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )
        )
    }
}

/// Symbol in einer abgerundeten Kachel mit feinem Rand, wie in der Seitenleiste.
struct IconTile: View {
    let systemName: String
    var size: CGFloat = 28
    var highlighted = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .light))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(highlighted ? Theme.accent : Color.white.opacity(0.85))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(Color.white.opacity(highlighted ? 0.08 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(Color.white.opacity(highlighted ? 0.22 : 0.13), lineWidth: 1)
            )
    }
}

/// Zeile der Seitenleiste: Symbol-Kachel und Text.
struct NavLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title).font(.system(size: 13))
        } icon: {
            IconTile(systemName: systemImage, size: 24)
        }
        .padding(.vertical, 2)
    }
}

/// Große, dünne Zahl mit kleiner Einheit daneben („157 GB“).
struct BigNumber: View {
    let value: String
    var unit: String?
    var size: CGFloat = 44

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: size, weight: .thin))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let unit {
                Text(unit).font(.system(size: size * 0.3, weight: .regular)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Größe aufgeteilt in Zahl und Einheit, z. B. ("42,1", "GB").
    static func bytesParts(_ value: Int64) -> (String, String) {
        let text = bytes(value)
        guard let space = text.lastIndex(where: { $0 == " " || $0 == "\u{00A0}" }) else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct DrillDown: ViewModifier {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .brightness(hovering ? 0.04 : 0)
            .onHover { hovering = $0 }
            .pointerStyle(.link)
            .onTapGesture(perform: action)
            .help(help)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: help, action)
    }
}
