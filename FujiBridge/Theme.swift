import SwiftUI
import UIKit

// thomas.md Quiet Ink. Paper and hairlines. Color only when a value is actually good or bad.

enum Ink {
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1
            )
        })
    }

    static let paper = adaptive(light: 0xfbfaf6, dark: 0x131110)
    static let ink = adaptive(light: 0x26231e, dark: 0xefebe2)
    static let ink2 = adaptive(light: 0x57534b, dark: 0xcfc9bf)
    static let muted = adaptive(light: 0x6e695f, dark: 0xa8a195)
    static let rule = adaptive(light: 0xe7e3da, dark: 0x2c2925)
    /// A panel one step off the paper: the camera card, the progress, empty tiles.
    static let surface = adaptive(light: 0xf2efe7, dark: 0x1c1a18)
    static let surface2 = adaptive(light: 0xe9e5db, dark: 0x262320)
    static let good = adaptive(light: 0x1baf7a, dark: 0x2ec48c)
    static let bad = adaptive(light: 0xeb6834, dark: 0xe07a4a)
    /// The warning tint behind a notice: the bad color, barely there.
    static let badWash = adaptive(light: 0xfcefe8, dark: 0x2a1a13)

    /// The Mac idiom ("Optimize for Mac") draws text at its point size, where a phone's body is 17 and a
    /// Mac's is 13. Fixed sizes chosen on one look wrong on the other, so sized fonts scale here: a little
    /// down on the Mac, and with Dynamic Type on the phone.
    static let isMac = ProcessInfo.processInfo.isMacCatalystApp

    private static func scaled(_ size: CGFloat, _ style: UIFont.TextStyle) -> CGFloat {
        if isMac { return (size * 0.88).rounded() }
        return UIFontMetrics(forTextStyle: style).scaledValue(for: size)
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size, .title3), weight: weight, design: .serif)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size, .footnote), weight: weight, design: .monospaced)
    }

    /// Sidebar text on the Mac: the system font at the sizes of the title bar and Finder's sidebar,
    /// 13 for a label and 11.5 for its second line, instead of scaled-down prose and monospace.
    static func side(_ role: SideRole, _ weight: Font.Weight? = nil) -> Font {
        let size: CGFloat
        let base: Font.Weight
        switch role {
        case .title: size = isMac ? 13 : 16; base = .medium
        case .detail: size = isMac ? 11.5 : 13; base = .regular
        case .header: size = isMac ? 11 : 13; base = .semibold
        case .name: size = isMac ? 15 : 18; base = .semibold
        }
        return .system(size: size, weight: weight ?? base)
    }

    enum SideRole { case title, detail, header, name }

    static func prose(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size, .body), weight: weight)
    }

    /// Corner radius of photos. Small, so a grid reads as pictures and not as cards.
    static let photoCorner: CGFloat = 4
}

struct Tag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Ink.mono(11, .medium))
            .tracking(1.6)
            .foregroundStyle(Ink.muted)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Ink.rule)
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}

struct Stat: View {
    let label: String
    let value: String
    var tone: Color = Ink.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Ink.mono(13))
                .foregroundStyle(Ink.ink2)
            Spacer(minLength: 12)
            Text(value)
                .font(Ink.mono(15, .medium))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(tone)
        }
    }
}

/// The press and hover feedback every Quiet Ink button shares.
struct InkPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

struct QuietButton: View {
    let title: String
    var filled = false
    var systemImage: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: Ink.isMac ? 13 : 15, weight: .medium)) }
                Text(title).font(Ink.serif(17, .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Ink.isMac ? 9 : 13)
            .foregroundStyle(filled ? Ink.paper : tone)
            .background(filled ? tone : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(filled ? Color.clear : Ink.rule, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(InkPress())
        .hoverEffect(.highlight)
    }

    private var tone: Color { role == .destructive ? Ink.bad : Ink.ink }
}

/// A small text button: "Clear", "Copy", "Stop". Same weight everywhere so they read as one family.
struct LinkButton: View {
    let title: String
    var systemImage: String? = nil
    var tone: Color = Ink.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(Ink.side(.title))
            .foregroundStyle(tone)
            .padding(.vertical, 6)
        }
        .buttonStyle(InkPress())
        .hoverEffect(.highlight)
    }
}

/// A rounded surface for a group of controls.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(Ink.isMac ? 14 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Every message the app shows about the state of things: a failed run, a camera that ignores us,
/// a hint. One shape, so an error never looks like a different app from a tip.
enum NoticeTone { case info, good, bad }

struct Notice<Actions: View>: View {
    typealias Tone = NoticeTone

    let tone: Tone
    let title: String
    var detail: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: Ink.isMac ? 13 : 15, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Ink.prose(15, .semibold))
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Ink.prose(14))
                        .foregroundStyle(Ink.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var icon: String {
        switch tone {
        case .info: return "info.circle"
        case .good: return "checkmark.circle"
        case .bad: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch tone {
        case .info: return Ink.muted
        case .good: return Ink.good
        case .bad: return Ink.bad
        }
    }

    private var background: Color { tone == .bad ? Ink.badWash : Ink.surface }
}

extension Notice where Actions == EmptyView {
    init(tone: Tone, title: String, detail: String? = nil) {
        self.init(tone: tone, title: title, detail: detail) { EmptyView() }
    }
}
