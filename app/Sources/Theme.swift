// Fond crème, encre prune, lavis lilas grainé et typographie géométrique.

import SwiftUI
import CoreText
import AppKit

enum Ink {
    static let paper = Color(hex: 0xFFFDF5)
    static let canvas = Color(hex: 0xF6F1EB)
    static let primary = Color(hex: 0x25041D)
    static let secondary = Color(hex: 0x70636C)
    static let muted = Color(hex: 0x766872)
    static let hairline = Color(hex: 0x25041D).opacity(0.10)
    static let wash = Color(hex: 0x25041D).opacity(0.045)
    static let indigo = Color(hex: 0x872168)
    static let coral = Color(hex: 0xBA493C)
    static let fresh = Color(hex: 0x287456)
    static let lavender = Color(hex: 0xEAE0FA)
    static let mint = Color(hex: 0xEAF4EC)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Typographie

extension View {
    func display(_ size: CGFloat = 32) -> some View {
        font(BrandFont.text(size, weight: .bold)).tracking(-size * 0.04).foregroundStyle(Ink.primary)
    }

    func body(_ size: CGFloat = 13.5, weight: Font.Weight = .regular) -> some View {
        font(BrandFont.text(size, weight: weight)).tracking(-0.15)
    }
}

// MARK: - Composants

/// Repère discret sur fond lilas.
struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(BrandFont.text(11, weight: .semibold))
            .tracking(0.1)
            .foregroundStyle(Ink.indigo)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Ink.lavender.opacity(0.7)))
    }
}

struct BlackButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        HoverBox { hovered in
            configuration.label
                .font(BrandFont.text(13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(Capsule().fill(Ink.primary.opacity(hovered ? 0.88 : 1)))
                .opacity(isEnabled ? 1 : 0.42)
                .contentShape(Rectangle())
        }
        .pressable(configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        HoverBox { hovered in
            configuration.label
                .font(BrandFont.text(12, weight: .semibold))
                .foregroundStyle(destructive ? Ink.coral : Ink.primary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Capsule().fill(hovered ? Ink.hairline : Ink.wash))
                .overlay(Capsule().stroke(Ink.hairline, lineWidth: 0.6))
                .opacity(isEnabled ? 1 : 0.42)
                .contentShape(Rectangle())
        }
        .pressable(configuration.isPressed)
    }
}

/// Suit le survol de la souris et le passe au contenu (avec un fondu court).
struct HoverBox<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovered = false
    var body: some View {
        content(hovered)
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h } }
    }
}

extension View {
    /// Léger enfoncement à ressort quand on clique.
    func pressable(_ pressed: Bool) -> some View {
        modifier(PressFeedback(pressed: pressed))
    }
}

/// Carte blanche à liseré fin.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.78)))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Ink.hairline, lineWidth: 0.8))
    }
}

/// Touche de clavier (comme la touche fn des démos du site).
struct Keycap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, 8)
            .frame(minWidth: 26, minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Ink.paper)
                    .shadow(color: .black.opacity(0.10), radius: 0, x: 0, y: 1.5)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.hairline, lineWidth: 0.8))
    }
}

/// Raccourci affiché en touches (« fn + ⌃ » → [fn] [⌃]).
struct ChordView: View {
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(label.components(separatedBy: " + ").enumerated()), id: \.offset) { _, key in
                Keycap(label: key)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).body(14, weight: .semibold).foregroundStyle(Ink.primary)
            if let subtitle {
                Text(subtitle).body(12.5).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle()
            .fill(ok ? Ink.fresh : Color(hex: 0xE8A33B))
            .frame(width: 7, height: 7)
            // Halo seulement quand il faut attirer l'œil.
            .background {
                if !ok {
                    Oscillator(period: 1.2) { phase in
                        Circle()
                            .fill(Color(hex: 0xE8A33B).opacity(0.45 * (1 - phase)))
                            .scaleEffect(1 + 1.6 * phase)
                    }
                    .transition(.identity)
                }
            }
    }
}

/// Animation périodique pilotée par une horloge qui s'arrête dès que la vue
/// disparaît. À préférer à `.repeatForever` : une animation sans fin dans
/// une vue retirée peut empêcher SwiftUI de finir le retrait, et la fenêtre
/// est alors redessinée à chaque image indéfiniment.
struct Oscillator<Content: View>: View {
    /// Durée d'un cycle en secondes.
    let period: Double
    /// Aller-retour (0 → 1 → 0) plutôt que dents de scie (0 → 1).
    var autoreverses = false
    @ViewBuilder var content: (Double) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            let phase = autoreverses ? (1 - cos(t * 2 * .pi)) / 2 : t
            content(reduceMotion ? 1 : phase)
        }
    }
}

/// Ligne de réglage : libellé, aide, interrupteur.
struct ToggleRow: View {
    let title: String
    let hint: String
    let isOn: Bool
    let set: (Bool) -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).body(13).foregroundStyle(Ink.primary)
                Text(hint).body(11.5).foregroundStyle(Ink.muted)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Ink.primary)
                .labelsHidden()
        }
        .padding(.vertical, 8)
    }
}

/// Puce sélectionnable (langue, modèle, ton).
struct Chip: View {
    let label: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? .white : Ink.primary)
                .padding(.horizontal, 11)
                .frame(height: 26)
        }
        .buttonStyle(ChipStyle(active: active))
        .animation(.snappy(duration: 0.22), value: active)
    }
}

struct ChipStyle: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        HoverBox { hovered in
            configuration.label
                .background(Capsule().fill(active ? Ink.primary : (hovered ? Ink.canvas : Ink.paper)))
                .overlay(Capsule().stroke(active ? Color.clear : Ink.hairline, lineWidth: 0.8))
                .contentShape(Capsule())
        }
        .pressable(configuration.isPressed)
    }
}

/// Champ de saisie sobre.
struct Field: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(Ink.paper))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.hairline, lineWidth: 0.8))
            .onSubmit(onSubmit)
    }
}

/// Flux de puces qui passe à la ligne.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}


/// Font and artwork are bundled: no network request during app use.
enum BrandFont {
    private static let registered: Void = {
        if let url = Bundle.main.url(forResource: "Manrope", withExtension: "ttf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        _ = registered
        return .custom("Manrope", size: size).weight(weight)
    }
}

struct AuroraBackdrop: View {
    private static let artwork: NSImage? = Bundle.main.url(forResource: "Aurora", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        GeometryReader { geometry in
            if let artwork = Self.artwork {
                Image(nsImage: artwork).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            } else { Ink.lavender }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct BrandGlyph: View {
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Ink.paper)
            .frame(width: size, height: size)
            .background(Ink.primary, in: RoundedRectangle(cornerRadius: size * 0.32))
            .accessibilityHidden(true)
    }
}

private struct PressFeedback: ViewModifier {
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            .opacity(pressed && reduceMotion ? 0.8 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: pressed)
    }
}
