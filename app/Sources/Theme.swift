// Style : blanc chaud, encre presque noire, boutons noirs, étiquettes indigo,
// lavis lavande.

import SwiftUI

enum Ink {
    static let paper = Color(hex: 0xFFFFFF)
    static let canvas = Color(hex: 0xFAF8F5)
    static let primary = Color(hex: 0x25221D)
    static let secondary = Color(red: 11 / 255, green: 10 / 255, blue: 9 / 255).opacity(0.6)
    static let muted = Color(red: 11 / 255, green: 10 / 255, blue: 9 / 255).opacity(0.4)
    static let hairline = Color(red: 11 / 255, green: 10 / 255, blue: 9 / 255).opacity(0.1)
    static let wash = Color(red: 11 / 255, green: 10 / 255, blue: 9 / 255).opacity(0.04)
    static let indigo = Color(hex: 0x463FA6)
    static let coral = Color(hex: 0xF55D48)
    static let fresh = Color(hex: 0x2FA866)
    static let lavender = Color(hex: 0xE9E6FB)
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
        font(.system(size: size, weight: .regular)).tracking(-size * 0.02).foregroundStyle(Ink.primary)
    }

    func body(_ size: CGFloat = 13.5, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight)).tracking(-0.2)
    }
}

// MARK: - Composants

/// Petite étiquette en capitales, cadre indigo.
struct Tag: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Ink.indigo)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Ink.indigo.opacity(0.55), lineWidth: 0.8))
    }
}

struct BlackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBox { hovered in
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 5).fill(Ink.primary.opacity(hovered ? 0.86 : 1)))
                .contentShape(Rectangle())
        }
        .pressable(configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        HoverBox { hovered in
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(destructive ? Ink.coral : Ink.primary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovered ? Ink.hairline : Ink.wash))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Ink.hairline, lineWidth: 0.6))
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
        scaleEffect(pressed ? 0.95 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.55), value: pressed)
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
            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.paper))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ink.hairline, lineWidth: 0.8))
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
