// Pastille flottante : capsule noire en bas de l'écran, icône de l'app où l'on
// dicte et forme d'onde blanche. NSPanel non activant (ne prend jamais le
// focus), traverse les Spaces et le plein écran, laisse passer les clics.
//
// Animations : la capsule jaillit avec un ressort (échelle + flou + fondu)
// et se rétracte à la fin ; sa largeur suit le mode (écoute, transcription,
// message) ; la forme d'onde est dessinée à chaque image (TimelineView +
// Canvas), chaque barre rejoignant sa cible par un ressort amorti.

import AppKit
import SwiftUI

@MainActor
final class PillPanel {
    static let shared = PillPanel()

    private let panel: NSPanel
    private let model = PillModel()
    private var hideWork: DispatchWorkItem?

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
    }

    func update(_ state: PillState) {
        let old = model.state
        // Les niveaux arrivent 30 fois par seconde : la forme d'onde les lit
        // directement à chaque image, sans redessiner toute la pastille. Le
        // reste de l'état ne la redessine que s'il change (mode, chronomètre…),
        // les changements de mode avec un ressort.
        model.level = state.levels.last ?? 0
        model.history = state.levels
        var stripped = state
        stripped.levels = old.levels
        if old.mode != state.mode || old.hands_free != state.hands_free || old.command != state.command
            || old.message != state.message {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { model.state = stripped }
        } else if stripped != old {
            model.state = stripped
        }

        if state.visible && !model.shown {
            hideWork?.cancel()
            model.mounted = true
            place()
            panel.orderFrontRegardless()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) { model.shown = true }
        } else if !state.visible && model.shown {
            withAnimation(.easeIn(duration: 0.16)) { model.shown = false }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.model.shown else { return }
                self.panel.orderOut(nil)
                self.model.mounted = false
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    /// Bas de l'écran où se trouve la souris, au-dessus du Dock.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 10))
    }
}

@MainActor
final class PillModel: ObservableObject {
    @Published var state = PillState()
    @Published var shown = false
    /// Contenu monté : retiré une fois la pastille rangée, pour qu'aucune
    /// animation ne tourne dans un panneau invisible.
    @Published var mounted = false
    /// Lus par la forme d'onde à chaque image, sans redessiner la vue.
    var level: Double = 0
    var history: [Double] = []
}

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        if model.mounted { capsule } else { Color.clear }
    }

    private var capsule: some View {
        let s = model.state
        return HStack(spacing: 10) {
            AppIcon(bundleId: s.bundle_id)
            content(s)
        }
        .padding(.leading, 8)
        .padding(.trailing, s.mode == "message" ? 16 : 14)
        .frame(height: 42)
        .background(
            Capsule()
                .fill(Color(hex: 0x111111))
                .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 8)
        )
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.8))
        .overlay(alignment: .topTrailing) {
            if s.command && s.mode != "message" {
                Text(tr("COMMANDE", "COMMAND"))
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Ink.indigo))
                    .offset(x: 10, y: -10)
                    .transition(.scale(scale: 0.4, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        // Apparition : jaillit du bas, comme une goutte.
        .scaleEffect(model.shown ? 1 : 0.55, anchor: .bottom)
        .blur(radius: model.shown ? 0 : 6)
        .opacity(model.shown ? 1 : 0)
        .offset(y: model.shown ? 0 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func content(_ s: PillState) -> some View {
        if s.mode == "message" {
            Text(s.message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
            HStack(spacing: 8) {
                if s.hands_free && s.mode == "listening" {
                    RecordingDot().transition(.scale.combined(with: .opacity))
                }
                Waveform(model: model, transcribing: s.mode == "transcribing", active: model.shown)
                if s.hands_free && s.mode == "listening" {
                    Text(String(format: "%d:%02d", s.secs / 60, s.secs % 60))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                        .contentTransition(.numericText())
                        .animation(.snappy, value: s.secs)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .transition(.opacity)
        }
    }
}

/// Point rouge des mains libres, qui respire.
struct RecordingDot: View {
    var body: some View {
        Oscillator(period: 1.6, autoreverses: true) { phase in
            Circle()
                .fill(Ink.coral)
                .frame(width: 7, height: 7)
                .shadow(color: Ink.coral.opacity(0.9 * phase), radius: 5 * phase)
                .scaleEffect(0.78 + 0.22 * phase)
        }
    }
}

// MARK: - Forme d'onde

/// Hauteurs affichées, conservées d'une image à l'autre.
@MainActor
final class WaveState {
    var heights: [CGFloat] = []
    var last: Date?
    var tTranscribe: Double = 0
}

struct Waveform: View {
    @ObservedObject var model: PillModel
    let transcribing: Bool
    /// Pastille visible : sinon l'horloge d'animation s'arrête (elle
    /// redessinait la vue à chaque image même pastille masquée).
    let active: Bool
    @State private var wave = WaveState()

    static let bars = 23
    private let barWidth: CGFloat = 3
    private let gap: CGFloat = 2.6
    private let maxHeight: CGFloat = 26
    private let minHeight: CGFloat = 3

    var body: some View {
        let width = CGFloat(Self.bars) * barWidth + CGFloat(Self.bars - 1) * gap
        // 60 images/s suffisent (un écran ProMotion en demanderait 120).
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let heights = step(now: timeline.date, t: t)
                for (i, h) in heights.enumerated() {
                    let x = CGFloat(i) * (barWidth + gap)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                    let alpha = transcribing ? 0.55 : 0.95
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.white.opacity(alpha)))
                }
            }
        }
        .frame(width: width, height: maxHeight + 2)
    }

    /// Fait avancer chaque barre vers sa cible (ressort amorti) et rend les
    /// hauteurs de l'image.
    private func step(now: Date, t: Double) -> [CGFloat] {
        let n = Self.bars
        if wave.heights.count != n { wave.heights = Array(repeating: minHeight, count: n) }
        let dt = min(max(now.timeIntervalSince(wave.last ?? now), 0), 0.05)
        wave.last = now
        let center = Double(n - 1) / 2
        let history = model.history
        let level = model.level

        for i in 0..<n {
            let d = abs(Double(i) - center)
            // Cloche : les barres du centre montent plus haut.
            let bell = 0.30 + 0.70 * exp(-pow(d / (Double(n) * 0.30), 2))
            var target: Double
            if transcribing {
                // Vague qui court pendant que whisper travaille.
                let w = sin(t * 7.0 - Double(i) * 0.55) * 0.5 + 0.5
                target = 0.10 + 0.22 * w * bell
            } else {
                // La voix part du centre : la barre au centre suit le niveau
                // actuel, ses voisines les niveaux un peu plus anciens.
                let k = history.count - 1 - Int(d.rounded() * 0.9)
                let past = (k >= 0 && k < history.count) ? history[k] : level
                let v = max(past, level * (1 - d / center * 0.6))
                // Petite agitation propre à chaque barre, pour que rien ne
                // paraisse figé même sur un son tenu.
                let speed = 6.0 + Double((i * 37) % 9)
                let jitter = 0.78 + 0.22 * sin(t * speed + Double(i) * 1.7)
                // Au repos, une respiration à peine visible.
                let idle = 0.04 * (sin(t * 2.4 + Double(i) * 0.45) * 0.5 + 0.5)
                target = max(v * bell * jitter, idle)
            }
            let goal = minHeight + CGFloat(min(target, 1)) * (maxHeight - minHeight)
            let rate: Double = goal > wave.heights[i] ? 26 : 12
            wave.heights[i] += (goal - wave.heights[i]) * CGFloat(1 - exp(-rate * dt))
        }
        return wave.heights
    }
}

/// Icône de l'app au premier plan au début de l'écoute (mise en cache).
struct AppIcon: View {
    let bundleId: String
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let image = Self.icon(for: bundleId) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "waveform").foregroundStyle(.white).font(.system(size: 12, weight: .semibold))
            }
        }
        .frame(width: 24, height: 24)
        .id(bundleId)
        .transition(.scale.combined(with: .opacity))
    }

    @MainActor
    private static func icon(for bundleId: String) -> NSImage? {
        guard !bundleId.isEmpty else { return nil }
        if let image = cache[bundleId] { return image }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleId] = image
        return image
    }
}
