// Accueil du premier lancement : sept étapes dans la fenêtre principale
// (bienvenue, modèle, micro, accessibilité, raccourci, essai, fin). Chaque
// étape est une colonne centrée ; les transitions sont des ressorts, réduites
// à un fondu quand « Réduire les animations » est activé. Retour = Continuer.

import AVFoundation
import AppKit
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, model, microphone, accessibility, shortcut, tryIt, done
}

struct OnboardingView: View {
    @EnvironmentObject var core: CoreModel
    @ObservedObject private var downloader = ModelDownloader.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: OnboardingStep = .welcome
    @State private var forward = true
    /// Modèle choisi à l'étape 2 (nom de fichier du catalogue).
    @State private var selectedModel: String?
    /// La zone d'essai a le focus : Retour y écrit, il ne passe pas l'étape.
    @State private var editorFocused = false
    @State private var trySucceeded = false

    private let column: CGFloat = 560

    var body: some View {
        ZStack {
            Ink.paper
            OnboardingWash()
            VStack(spacing: 0) {
                StepIndicator(current: step, reduceMotion: reduceMotion)
                    .padding(.top, 50)
                    .padding(.bottom, 4)
                GeometryReader { geo in
                    ScrollView(showsIndicators: false) {
                        ZStack {
                            content
                                .frame(maxWidth: column)
                                .padding(.horizontal, 40)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                                .id(step)
                                .transition(stepTransition)
                        }
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                }
                footer
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .ignoresSafeArea()
        .preferredColorScheme(.light)
        .onAppear(perform: pickDefaultModel)
        .onChange(of: core.state.catalog) { _, _ in pickDefaultModel() }
    }

    // MARK: - Étapes

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep(reduceMotion: reduceMotion)
        case .model: ModelStep(selected: $selectedModel)
        case .microphone: MicrophoneStep()
        case .accessibility: AccessibilityStep()
        case .shortcut: ShortcutStep()
        case .tryIt: TryItStep(editorFocused: $editorFocused, succeeded: $trySucceeded, reduceMotion: reduceMotion)
        case .done: DoneStep(reduceMotion: reduceMotion)
        }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let dx: CGFloat = forward ? 56 : -56
        return .asymmetric(
            insertion: .offset(x: dx).combined(with: .opacity),
            removal: .offset(x: -dx).combined(with: .opacity)
        )
    }

    private var stepAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.48, dampingFraction: 0.86)
    }

    private func go(_ to: OnboardingStep) {
        guard to != step else { return }
        forward = to.rawValue > step.rawValue
        withAnimation(stepAnimation) { step = to }
    }

    private func next() {
        switch step {
        case .model:
            // Le modèle choisi est déjà là : le cœur l'utilise dès maintenant.
            if let file = selectedModel, let m = core.state.catalog.first(where: { $0.file == file }), m.installed,
               core.state.prefs.model != file {
                core.setPref("model", file)
            }
        case .done:
            core.finishOnboarding()
            return
        default:
            break
        }
        if let n = OnboardingStep(rawValue: step.rawValue + 1) { go(n) }
    }

    private func back() {
        if let p = OnboardingStep(rawValue: step.rawValue - 1) { go(p) }
    }

    /// Présélection : le modèle recommandé, ou le premier déjà installé si le
    /// recommandé ne l'est pas.
    private func pickDefaultModel() {
        guard selectedModel == nil, !core.state.catalog.isEmpty else { return }
        let catalog = core.state.catalog
        let recommended = catalog.first { $0.recommended }
        if let r = recommended, r.installed { selectedModel = r.file }
        else if let i = catalog.first(where: { $0.installed }) { selectedModel = i.file }
        else { selectedModel = (recommended ?? catalog[0]).file }
    }

    // MARK: - Pied : Retour, état, Continuer

    private var canContinue: Bool {
        switch step {
        case .model:
            return core.state.catalog.contains { $0.installed } || downloader.isActive || downloader.phase == .done
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined || core.state.audio_started
        default:
            return true
        }
    }

    private var continueLabel: String {
        switch step {
        case .welcome: tr("Commencer", "Get started")
        case .tryIt: trySucceeded ? tr("Continuer", "Continue") : tr("Passer", "Skip")
        case .done: tr("Commencer à dicter", "Start dictating")
        default: tr("Continuer", "Continue")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(tr("Retour", "Back"), action: back)
                .buttonStyle(QuietButtonStyle())
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)
            Spacer()
            footerStatus
            Spacer()
            continueButton
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    @ViewBuilder
    private var footerStatus: some View {
        if step != .model, step != .done, downloader.isActive, let m = downloader.model {
            Button { go(.model) } label: {
                HStack(spacing: 8) {
                    ProgressRing(progress: downloader.progress, indeterminate: downloader.phase == .verifying)
                    Text(tr("Téléchargement · \(m.label.components(separatedBy: " (")[0]) · \(Int(downloader.progress * 100)) %",
                            "Downloading · \(m.label.components(separatedBy: " (")[0]) · \(Int(downloader.progress * 100))%"))
                        .body(11.5).foregroundStyle(Ink.secondary).monospacedDigit()
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Ink.canvas))
                .overlay(Capsule().stroke(Ink.hairline, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
            Text(tr("Étape \(step.rawValue + 1) sur \(OnboardingStep.allCases.count)",
                    "Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)"))
                .body(11.5).foregroundStyle(Ink.muted)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var continueButton: some View {
        let button = Button(action: next) {
            HStack(spacing: 6) {
                Text(continueLabel)
                if step != .done { Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)) }
            }
            .frame(minWidth: 96)
        }
        .buttonStyle(BlackButtonStyle())
        .disabled(!canContinue)
        .opacity(canContinue ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.2), value: canContinue)
        if step == .tryIt && editorFocused {
            button
        } else {
            button.keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Décor et indicateur d'étapes

/// Lavis menthe → lavande très doux dans les coins (la direction du site).
struct OnboardingWash: View {
    var body: some View {
        AuroraBackdrop().opacity(0.62).allowsHitTesting(false)
    }
}

struct StepIndicator: View {
    let current: OnboardingStep
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= current.rawValue ? Ink.primary : Ink.hairline)
                    .frame(width: s == current ? 22 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.8), value: current)
        .accessibilityLabel(tr("Étape \(current.rawValue + 1) sur \(OnboardingStep.allCases.count)",
                               "Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count)"))
    }
}

/// En-tête d'étape : étiquette, titre, explication.
struct StepHeader: View {
    let tag: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Tag(text: tag)
            Text(title).display(28)
            Text(subtitle).body(13.5).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Étiquette colorée (« Installé » en vert, « Recommandé » en indigo).
struct ColorTag: View {
    let text: String
    var color: Color = Ink.indigo
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.55), lineWidth: 0.8))
    }
}

/// Ligne « fait » : coche verte et texte.
struct DoneRow: View {
    let text: String
    var detail: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            CheckBadge(size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).body(13.5, weight: .medium).foregroundStyle(Ink.primary)
                if let detail { Text(detail).body(12).foregroundStyle(Ink.secondary) }
            }
            Spacer()
        }
    }
}

/// Coche dans un disque vert pâle, qui jaillit à l'apparition.
struct CheckBadge: View {
    var size: CGFloat = 26
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    var body: some View {
        ZStack {
            Circle().fill(Ink.fresh.opacity(0.14))
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(Ink.fresh)
        }
        .frame(width: size, height: size)
        .scaleEffect(shown || reduceMotion ? 1 : 0.4)
        .opacity(shown || reduceMotion ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.38, dampingFraction: 0.6)) { shown = true } }
    }
}

/// Avertissement corail avec action.
struct NoticeBox: View {
    let text: String
    var action: String? = nil
    var run: () -> Void = {}
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Ink.coral)
            Text(text).body(12.5).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action { Button(action, action: run).buttonStyle(BlackButtonStyle()) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.coral.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.coral.opacity(0.25), lineWidth: 0.8))
    }
}

/// Petit anneau de progression (pied de page pendant un téléchargement).
struct ProgressRing: View {
    let progress: Double
    var indeterminate = false
    var body: some View {
        ZStack {
            Circle().stroke(Ink.hairline, lineWidth: 2)
            if indeterminate {
                Oscillator(period: 1) { phase in
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Ink.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90 + 360 * phase))
                }
            } else {
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Ink.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 12, height: 12)
        .animation(.linear(duration: 0.3), value: progress)
    }
}

func openSystemSettings(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
}

// MARK: - Logo « Écho » animé

/// Barre d'encre à cœur indigo et anneaux. Animé : des anneaux naissent
/// contre la barre, s'élargissent et s'effacent (comme une voix qui porte).
struct EchoLogo: View {
    var size: CGFloat = 120
    var animated = true

    var body: some View {
        TimelineView(.animation(paused: !animated)) { timeline in
            Canvas { ctx, s in
                let u = s.width / 100
                let t = timeline.date.timeIntervalSinceReferenceDate
                let ink = Ink.primary
                func capsule(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
                    Path(roundedRect: CGRect(x: x * u, y: y * u, width: w * u, height: h * u), cornerRadius: min(w, h) * u / 2)
                }
                // Anneaux fixes, de plus en plus pâles (l'icône).
                let opacities: [Double] = [0.55, 0.32, 0.16]
                for k in 1...3 {
                    let gap = 8 * CGFloat(k)
                    ctx.stroke(capsule(45.5 - gap, 33 - gap, 9 + 2 * gap, 34 + 2 * gap),
                               with: .color(ink.opacity(opacities[k - 1] * (animated ? 0.55 : 1))), lineWidth: 2.4 * u)
                }
                // Anneaux émis : deux en vol, période lente.
                if animated {
                    let period = 3.2
                    for i in 0..<2 {
                        let p = ((t / period) + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                        let eased = 1 - pow(1 - p, 2)
                        let gap = 4 + 28 * CGFloat(eased)
                        let alpha = pow(1 - p, 1.6) * 0.5
                        ctx.stroke(capsule(45.5 - gap, 33 - gap, 9 + 2 * gap, 34 + 2 * gap),
                                   with: .color(ink.opacity(alpha)), lineWidth: 2.4 * u)
                    }
                }
                ctx.fill(capsule(45.5, 33, 9, 34), with: .color(ink))
                // Cœur indigo qui respire à peine.
                let breath = animated ? 1 + 0.06 * sin(t * 1.6) : 1
                let ch = 12 * breath
                ctx.fill(capsule(47.4, 50 - ch / 2, 5.2, ch), with: .color(Ink.indigo))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Petite pastille (capsule noire, barres blanches en cloche) : au repos elle
/// respire, à l'écoute elle suit les niveaux du micro, pendant la
/// transcription une vague court.
struct MiniPill: View {
    var levels: [Double] = []
    var mode = "idle"
    var animated = true
    @State private var smooth = MiniPillState()

    var body: some View {
        let n = 15
        TimelineView(.animation(paused: !animated)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let bw: CGFloat = 2.6, gap: CGFloat = 2.4, maxH: CGFloat = 18, minH: CGFloat = 2.5
                let total = CGFloat(n) * bw + CGFloat(n - 1) * gap
                let x0 = (size.width - total) / 2
                if smooth.h.count != n { smooth.h = Array(repeating: minH, count: n) }
                let center = Double(n - 1) / 2
                for i in 0..<n {
                    let d = abs(Double(i) - center)
                    let bell = 0.3 + 0.7 * exp(-pow(d / (Double(n) * 0.3), 2))
                    var target: Double
                    switch mode {
                    case "listening":
                        let k = levels.count - 1 - Int(d.rounded())
                        let past = (k >= 0 && k < levels.count) ? levels[k] : (levels.last ?? 0)
                        let jitter = 0.8 + 0.2 * sin(t * (6 + Double(i % 5)) + Double(i))
                        target = max(past * bell * jitter, 0.06)
                    case "transcribing":
                        let w = sin(t * 7 - Double(i) * 0.55) * 0.5 + 0.5
                        target = 0.1 + 0.25 * w * bell
                    default:
                        target = 0.05 + 0.07 * bell * (sin(t * 2.2 + Double(i) * 0.5) * 0.5 + 0.5)
                    }
                    let goal = minH + CGFloat(min(target, 1)) * (maxH - minH)
                    smooth.h[i] += (goal - smooth.h[i]) * (animated ? 0.25 : 1)
                    let h = smooth.h[i]
                    let rect = CGRect(x: x0 + CGFloat(i) * (bw + gap), y: (size.height - h) / 2, width: bw, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: bw / 2), with: .color(.white.opacity(mode == "transcribing" ? 0.6 : 0.95)))
                }
            }
        }
        .frame(width: 96, height: 32)
        .background(Capsule().fill(Color(hex: 0x111111)).shadow(color: .black.opacity(0.18), radius: 8, y: 4))
        .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 0.8))
        .accessibilityHidden(true)
    }
}

final class MiniPillState {
    var h: [CGFloat] = []
}

// MARK: - 1. Bienvenue

struct WelcomeStep: View {
    let reduceMotion: Bool
    @State private var shown = false

    var body: some View {
        VStack(spacing: 30) {
            EchoLogo(size: 128, animated: !reduceMotion)
                .reveal(shown, delay: 0, reduceMotion: reduceMotion)
            VStack(spacing: 14) {
                Tag(text: tr("Bienvenue chez vous", "Make yourself at home"))
                Text(tr("Vos idées à voix haute.\nLe reste, c’est Diktation.", "Your ideas, out loud.\nDiktation does the rest."))
                    .display(40).lineSpacing(3).multilineTextAlignment(.center)
                Text(tr("Maintenez une touche, parlez, relâchez : le texte apparaît là où est votre curseur, dans n'importe quelle app.",
                        "Hold a key, speak, release: the text appears where your cursor is, in any app."))
                    .body(14.5).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            .reveal(shown, delay: 0.12, reduceMotion: reduceMotion)
            HStack(spacing: 10) {
                promise("lock.fill", tr("Rien ne quitte ce Mac", "Nothing leaves this Mac"))
                promise("person.crop.circle.badge.xmark", tr("Aucun compte", "No account"))
                promise("creditcard", tr("Aucun abonnement", "No subscription"))
            }
            .reveal(shown, delay: 0.24, reduceMotion: reduceMotion)
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { shown = true } }
    }

    private func promise(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.indigo)
            Text(text).body(12, weight: .medium).foregroundStyle(Ink.primary)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Ink.paper))
        .overlay(Capsule().stroke(Ink.hairline, lineWidth: 0.8))
    }
}

extension View {
    /// Apparition en cascade : fondu et léger glissement, avec un délai.
    func reveal(_ shown: Bool, delay: Double, reduceMotion: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(reduceMotion ? .easeOut(duration: 0.25).delay(delay)
                       : .spring(response: 0.7, dampingFraction: 0.85).delay(delay), value: shown)
    }
}

// MARK: - 2. Modèle de transcription

struct ModelStep: View {
    @EnvironmentObject var core: CoreModel
    @ObservedObject private var downloader = ModelDownloader.shared
    @Binding var selected: String?

    var body: some View {
        let s = core.state
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(tag: tr("Transcription", "Transcription"),
                       title: tr("Modèle de transcription", "Transcription model"),
                       subtitle: tr("Whisper tourne sur ce Mac. Choisissez la langue de vos dictées et le modèle qui les écrit.",
                                    "Whisper runs on this Mac. Pick the language you dictate in and the model that writes it down."))
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(tr("Langue de dictée", "Dictation language"))
                FlowLayout(spacing: 6) {
                    ForEach(s.languages) { l in
                        Chip(label: l.label, active: s.prefs.language == l.code) { core.setPref("language", l.code) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(tr("Modèle", "Model"))
                VStack(spacing: 5) {
                    ForEach(s.catalog) { m in
                        ModelRow(model: m, selected: selected == m.file) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selected = m.file }
                        }
                    }
                }
            }
            // Hauteur fixe : la carte change d'état sans déplacer le reste.
            actionArea
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 92, alignment: .top)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(Ink.muted)
    }

    private var selectedModel: CatalogModel? { core.state.catalog.first { $0.file == selected } }

    /// Carte de téléchargement si elle concerne le modèle choisi (ou si un
    /// téléchargement est en cours), sinon l'action propre à la sélection.
    @ViewBuilder
    private var actionArea: some View {
        if downloader.phase != .idle, let dm = downloader.model, downloader.isActive || dm.file == selected {
            DownloadCard(model: dm)
                .transition(.opacity.combined(with: .offset(y: 6)))
        } else if let m = selectedModel {
            Card(padding: 12) {
                if m.installed {
                    DoneRow(text: tr("Déjà installé sur ce Mac", "Already installed on this Mac"),
                            detail: tr("Rien à télécharger : vous pouvez continuer.", "Nothing to download: you can continue."))
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tr("À télécharger une seule fois", "Downloaded once"))
                                .body(13.5, weight: .medium).foregroundStyle(Ink.primary)
                            Text(tr("\(ModelDownloader.format(bytes: m.bytes)) depuis Hugging Face, puis plus jamais besoin du réseau. Vous pouvez continuer pendant le téléchargement.",
                                    "\(ModelDownloader.format(bytes: m.bytes)) from Hugging Face, then the network is never needed again. You can continue while it downloads."))
                                .body(12).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(tr("Télécharger", "Download")) { downloader.start(m, into: core.state.install_dir) }
                            .buttonStyle(BlackButtonStyle())
                    }
                }
            }
            .id(m.file + (m.installed ? "-i" : ""))
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
}

struct ModelRow: View {
    let model: CatalogModel
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let parts = model.label.components(separatedBy: " (")
        let title = parts[0]
        let detail = parts.count > 1 ? parts[1].replacingOccurrences(of: ")", with: "") : nil
        let hint: String? = model.recommended
            ? tr("rapide et précis", "fast and accurate")
            : detail
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(selected ? Ink.primary : Ink.hairline, lineWidth: selected ? 1.4 : 1)
                    Circle().fill(Ink.primary).frame(width: 8, height: 8).scaleEffect(selected ? 1 : 0.01).opacity(selected ? 1 : 0)
                }
                .frame(width: 16, height: 16)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).body(13.5, weight: .medium).foregroundStyle(Ink.primary).layoutPriority(1)
                    if let hint {
                        Text(hint).body(11.5).foregroundStyle(Ink.muted).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if model.installed { ColorTag(text: tr("Installé", "Installed"), color: Ink.fresh) }
                    if model.recommended { ColorTag(text: tr("Recommandé", "Recommended")) }
                    Text(ModelDownloader.format(bytes: model.bytes))
                        .body(12).foregroundStyle(Ink.secondary).monospacedDigit().frame(width: 58, alignment: .trailing)
                }
                .layoutPriority(2)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.paper))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Ink.primary : Ink.hairline, lineWidth: selected ? 1.2 : 0.8))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selected)
    }
}

/// Progression, débit, temps restant, annulation et reprise.
struct DownloadCard: View {
    @ObservedObject private var downloader = ModelDownloader.shared
    let model: CatalogModel

    var body: some View {
        let title = model.label.components(separatedBy: " (")[0]
        Card(padding: 12) {
            switch downloader.phase {
            case .done:
                DoneRow(text: tr("\(title) téléchargé et installé", "\(title) downloaded and installed"),
                        detail: tr("Le cœur charge le modèle. Vous pouvez continuer.", "The engine is loading the model. You can continue."))
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(Ink.coral)
                        Text(message).body(12.5).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(tr("Abandonner", "Give up")) { downloader.reset() }.buttonStyle(QuietButtonStyle())
                        Button(tr("Réessayer", "Retry")) { downloader.retry() }.buttonStyle(BlackButtonStyle())
                    }
                    if downloader.received > 0 { bar }
                }
            case .cancelled:
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(tr("Téléchargement en pause", "Download paused")).body(13.5, weight: .medium).foregroundStyle(Ink.primary)
                        Spacer()
                        Button(tr("Abandonner", "Give up")) { downloader.reset() }.buttonStyle(QuietButtonStyle())
                        Button(tr("Reprendre", "Resume")) { downloader.retry() }.buttonStyle(BlackButtonStyle())
                    }
                    bar
                }
            default:
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(downloader.phase == .verifying ? tr("Vérification du fichier…", "Checking the file…")
                             : tr("Téléchargement de \(title)…", "Downloading \(title)…"))
                            .body(13.5, weight: .medium).foregroundStyle(Ink.primary)
                        Spacer()
                        if downloader.phase == .downloading {
                            Button(tr("Annuler", "Cancel")) { downloader.cancel() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    bar
                    HStack(spacing: 0) {
                        Text("\(ModelDownloader.format(bytes: downloader.received)) / \(ModelDownloader.format(bytes: max(downloader.total, model.bytes)))")
                        if downloader.speed > 0 {
                            Text(" · \(ModelDownloader.format(speed: downloader.speed))")
                        }
                        if let eta = downloader.eta {
                            Text(" · \(ModelDownloader.format(eta: eta))")
                        }
                        Spacer()
                        Text("\(Int(downloader.progress * 100)) %")
                    }
                    .body(11.5).foregroundStyle(Ink.secondary).monospacedDigit()
                    .contentTransition(.numericText())
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: downloader.phase)
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.hairline)
                Capsule()
                    .fill(LinearGradient(colors: [Ink.indigo, Ink.primary], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * downloader.progress))
                    .animation(.linear(duration: 0.3), value: downloader.progress)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - 3. Microphone

struct MicrophoneStep: View {
    @EnvironmentObject var core: CoreModel
    @State private var status = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(tag: tr("Micro", "Microphone"),
                       title: tr("Microphone", "Microphone"),
                       subtitle: tr("Diktation n'écoute que pendant que vous maintenez le raccourci. L'audio est transcrit sur ce Mac et n'est jamais envoyé.",
                                    "Diktation only listens while you hold the shortcut. Audio is transcribed on this Mac and never sent anywhere."))
            HStack(spacing: 14) {
                MiniPill(mode: status == .authorized ? "idle" : "idle", animated: status == .authorized)
                Text(status == .authorized
                     ? tr("La pastille apparaît en bas de l'écran pendant que vous parlez.", "The pill shows at the bottom of the screen while you speak.")
                     : tr("La pastille apparaîtra en bas de l'écran pendant que vous parlez.", "The pill will show at the bottom of the screen while you speak."))
                    .body(12.5).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Card {
                switch status {
                case .authorized:
                    DoneRow(text: tr("Micro autorisé", "Microphone allowed"),
                            detail: tr("Diktation écoute seulement quand vous le lui demandez.", "Diktation listens only when you ask it to."))
                case .notDetermined:
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tr("Autoriser l'accès au micro", "Allow microphone access"))
                                .body(13.5, weight: .medium).foregroundStyle(Ink.primary)
                            Text(tr("macOS va vous demander confirmation.", "macOS will ask you to confirm."))
                                .body(12).foregroundStyle(Ink.secondary)
                        }
                        Spacer()
                        Button(tr("Autoriser le micro", "Allow microphone"), action: request)
                            .buttonStyle(BlackButtonStyle())
                            .disabled(asking)
                    }
                default:
                    VStack(alignment: .leading, spacing: 12) {
                        NoticeBox(text: tr("L'accès au micro est refusé. Dans Réglages Système → Confidentialité et sécurité → Microphone, activez Diktation, puis revenez ici.",
                                           "Microphone access is denied. In System Settings → Privacy & Security → Microphone, turn on Diktation, then come back here."),
                                  action: tr("Ouvrir les Réglages", "Open Settings")) {
                            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                        }
                        Button(tr("Vérifier à nouveau", "Check again"), action: refresh).buttonStyle(QuietButtonStyle())
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: status)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized, !core.state.audio_started { core.send("start_audio") }
    }

    private func request() {
        asking = true
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                asking = false
                refresh()
            }
        }
    }
}

// MARK: - 4. Accessibilité

struct AccessibilityStep: View {
    @EnvironmentObject var core: CoreModel
    @State private var asked = false

    var body: some View {
        // Avant le premier instantané du cœur, `accessibility` vaut vrai par
        // défaut : on attend un vrai état.
        let granted = core.state.accessibility && !core.state.install_dir.isEmpty
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(tag: tr("Autorisation", "Permission"),
                       title: tr("Accessibilité", "Accessibility"),
                       subtitle: tr("Nécessaire pour deux choses : entendre le raccourci dans toutes les apps, et coller le texte dicté là où se trouve votre curseur.",
                                    "Needed for two things: hearing the shortcut in every app, and pasting the dictated text where your cursor is."))
            HStack(spacing: 10) {
                reason("keyboard", tr("Raccourci global", "Global shortcut"), tr("fonctionne dans toutes les apps", "works in every app"))
                reason("text.cursor", tr("Collage", "Pasting"), tr("le texte arrive sous le curseur", "the text lands under the cursor"))
                reason("eye.slash", tr("Rien d'autre", "Nothing else"), tr("Diktation ne lit pas ce que vous tapez", "Diktation does not read what you type"))
            }
            // Même hauteur pour les trois cartes (la plus haute donne la mesure).
            .fixedSize(horizontal: false, vertical: true)
            Card {
                if granted {
                    DoneRow(text: tr("Accessibilité accordée", "Accessibility granted"),
                            detail: tr("Le raccourci est actif dans toutes vos apps.", "The shortcut is active in all your apps."))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tr("Autoriser Diktation", "Allow Diktation")).body(13.5, weight: .medium).foregroundStyle(Ink.primary)
                                Text(tr("Les Réglages Système s'ouvrent : activez Diktation dans la liste, puis revenez ici. La coche apparaît toute seule.",
                                        "System Settings opens: turn on Diktation in the list, then come back here. The checkmark appears on its own."))
                                    .body(12).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button(asked ? tr("Rouvrir les Réglages", "Reopen Settings") : tr("Autoriser", "Allow")) {
                                asked = true
                                core.send("prompt_accessibility")
                            }
                            .buttonStyle(BlackButtonStyle())
                        }
                        if asked {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(tr("En attente de l'autorisation…", "Waiting for permission…")).body(12).foregroundStyle(Ink.muted)
                            }
                            .transition(.opacity)
                        }
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: granted)
            .animation(.easeInOut(duration: 0.2), value: asked)
        }
    }

    private func reason(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.indigo)
                .frame(height: 18, alignment: .center)
            Text(title).body(12.5, weight: .medium).foregroundStyle(Ink.primary)
            Text(detail).body(11.5).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.canvas))
    }
}

// MARK: - 5. Raccourci

struct ShortcutStep: View {
    @EnvironmentObject var core: CoreModel

    var body: some View {
        let s = core.state
        let conflict = s.fn_conflict && s.chord_label.contains("fn")
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(tag: tr("Raccourci", "Shortcut"),
                       title: tr("Un geste pour dicter", "One gesture to dictate"),
                       subtitle: tr("Le même raccourci partout : maintenez-le pour parler, relâchez pour écrire.",
                                    "The same shortcut everywhere: hold it to speak, release to write."))
            Card {
                HStack(spacing: 16) {
                    Group {
                        if s.recording_chord {
                            RecordingLabel()
                        } else {
                            BigChord(label: s.chord_label).transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    .frame(minHeight: 48)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: s.recording_chord)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: s.chord_label)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.recording_chord ? tr("Appuyez sur les touches voulues", "Press the keys you want")
                             : tr("Votre raccourci", "Your shortcut"))
                            .body(13.5, weight: .medium).foregroundStyle(Ink.primary)
                        Text(tr("Modificateurs seuls : fn, ⌃, ⌥, ⌘, ⇧, ou une combinaison.",
                                "Modifier keys only: fn, ⌃, ⌥, ⌘, ⇧, or a combination."))
                            .body(12).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(s.recording_chord ? tr("Annuler", "Cancel") : tr("Changer", "Change")) {
                        core.send("record_chord", ["on": !s.recording_chord])
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
            Card(padding: 0) {
                gesture(chord: s.chord_label, title: tr("Maintenir", "Hold"), detail: tr("Parlez, puis relâchez : le texte apparaît.", "Speak, then release: the text appears."))
                Divider().overlay(Ink.hairline)
                gesture(chord: s.chord_label + " ×2", title: tr("Double appui", "Double tap"),
                        detail: tr("Mains libres : Diktation écoute jusqu'au prochain appui.", "Hands-free: Diktation listens until the next tap."))
                Divider().overlay(Ink.hairline)
                gesture(chord: "esc", title: tr("Annuler", "Cancel"), detail: tr("Abandonne la dictée en cours, rien n'est collé.", "Drops the current dictation, nothing is pasted."))
            }
            if conflict {
                NoticeBox(text: tr("La touche fn / 🌐 ouvre aussi un outil macOS. Pour éviter le doublon : Réglages Système → Clavier → « Appuyer sur la touche 🌐 pour » → « Ne rien faire ».",
                                   "The fn / 🌐 key also opens a macOS tool. To avoid both firing: System Settings → Keyboard → “Press 🌐 key to” → “Do Nothing”."),
                          action: tr("Ouvrir Clavier", "Open Keyboard")) {
                    openSystemSettings("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
                }
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: conflict)
    }

    private func gesture(chord: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            ChordView(label: chord).frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).body(13).foregroundStyle(Ink.primary)
                Text(detail).body(11.5).foregroundStyle(Ink.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// Touches grand format pour l'étape du raccourci.
struct BigChord: View {
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(label.components(separatedBy: " + ").enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(Ink.primary)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 48, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Ink.paper)
                            .shadow(color: .black.opacity(0.12), radius: 0, x: 0, y: 2.5)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Ink.hairline, lineWidth: 0.8))
            }
        }
    }
}

/// Point indigo qui pulse pendant l'enregistrement d'un raccourci.
struct RecordingLabel: View {
    var body: some View {
        HStack(spacing: 8) {
            Oscillator(period: 1.2, autoreverses: true) { phase in
                Circle().fill(Ink.indigo).frame(width: 8, height: 8).opacity(0.25 + 0.75 * phase)
            }
            Text(tr("Écoute du clavier…", "Listening to the keyboard…")).body(13).foregroundStyle(Ink.indigo)
        }
        .frame(minWidth: 48)
        .transition(.opacity)
    }
}

// MARK: - 6. Essai

struct TryItStep: View {
    @EnvironmentObject var core: CoreModel
    @ObservedObject private var downloader = ModelDownloader.shared
    @Binding var editorFocused: Bool
    @Binding var succeeded: Bool
    let reduceMotion: Bool

    @State private var text = ""
    @State private var baseline: Int64?
    @State private var armed = false
    @State private var burst = false
    @FocusState private var focus: Bool

    var body: some View {
        let s = core.state
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(tag: tr("Essai", "Try it"),
                       title: succeeded ? tr("Et voilà.", "There it is.") : tr("Essayez maintenant", "Try it now"),
                       subtitle: succeeded
                           ? tr("Ça marche pareil dans Mail, Slack, votre navigateur… partout où il y a un curseur.",
                                "It works the same in Mail, Slack, your browser… anywhere there is a cursor.")
                           : tr("Cliquez dans la zone, maintenez \(s.chord_label), dites une phrase, relâchez.",
                                "Click in the box, hold \(s.chord_label), say a sentence, release."))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.primary)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .focused($focus)
                if text.isEmpty {
                    Text(tr("Votre dictée apparaîtra ici…", "Your dictation will appear here…"))
                        .font(.system(size: 15)).foregroundStyle(Ink.muted)
                        .padding(.horizontal, 17).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                if burst {
                    SuccessBurst(reduceMotion: reduceMotion)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.paper))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(succeeded ? Ink.fresh.opacity(0.7) : (focus ? Ink.indigo.opacity(0.7) : Ink.hairline),
                            lineWidth: focus || succeeded ? 1.4 : 0.8)
            )
            .animation(.easeInOut(duration: 0.2), value: focus)
            .animation(.easeInOut(duration: 0.3), value: succeeded)
            statusLine(s)
                .frame(minHeight: 40, alignment: .leading)
        }
        .onAppear {
            baseline = core.state.history.first?.id
            armed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focus = true }
        }
        .onChange(of: focus) { _, f in editorFocused = f }
        .onDisappear { editorFocused = false }
        .onChange(of: core.state.history.first?.id) { _, new in
            guard armed, !succeeded, let new, new != baseline else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                succeeded = true
                burst = true
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ s: AppState) -> some View {
        let p = core.pill
        if succeeded {
            HStack(spacing: 12) {
                CheckBadge(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Première dictée réussie", "First dictation done")).body(13.5, weight: .medium).foregroundStyle(Ink.primary)
                    if let last = s.history.first, !last.text.isEmpty {
                        Text(tr("\(last.text.split(separator: " ").count) mots en \(String(format: "%.1f", last.seconds)) s", "\(last.text.split(separator: " ").count) words in \(String(format: "%.1f", last.seconds)) s"))
                            .body(12).foregroundStyle(Ink.secondary)
                    }
                }
            }
            .transition(.opacity.combined(with: .offset(y: 6)))
        } else if !s.engine.ready {
            HStack(spacing: 12) {
                if downloader.isActive {
                    ProgressRing(progress: downloader.progress, indeterminate: downloader.phase == .verifying)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(downloader.isActive
                         ? tr("Le modèle se télécharge encore · \(Int(downloader.progress * 100)) %", "The model is still downloading · \(Int(downloader.progress * 100))%")
                         : (s.engine.failed ? tr("Aucun modèle prêt", "No model ready") : tr("Le modèle se charge…", "Loading the model…")))
                        .body(13).foregroundStyle(Ink.primary).monospacedDigit()
                    Text(downloader.isActive
                         ? (downloader.eta.map { ModelDownloader.format(eta: $0) } ?? tr("Encore un instant…", "Just a moment…"))
                         : (s.engine.failed ? s.engine.status : tr("Quelques secondes, puis vous pourrez essayer.", "A few seconds, then you can try.")))
                        .body(12).foregroundStyle(Ink.secondary)
                }
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 12) {
                MiniPill(levels: p.levels, mode: p.visible ? p.mode : "idle", animated: !reduceMotion || p.visible)
                Text(p.visible
                     ? (p.mode == "transcribing" ? tr("Transcription…", "Transcribing…") : tr("Je vous écoute…", "Listening…"))
                     : tr("Prêt · maintenez \(s.chord_label) et parlez", "Ready · hold \(s.chord_label) and speak"))
                    .body(13).foregroundStyle(p.visible ? Ink.indigo : Ink.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: p.visible)
            }
            .transition(.opacity)
        }
    }
}

/// Anneaux qui s'élargissent une fois depuis le centre (réussite).
struct SuccessBurst: View {
    let reduceMotion: Bool
    @State private var go = false
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Ink.fresh.opacity(go ? 0 : 0.5), lineWidth: 2)
                    .frame(width: 40, height: 40)
                    .scaleEffect(go ? 6 + CGFloat(i) * 2 : 0.4)
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.1).delay(Double(i) * 0.14), value: go)
            }
        }
        .opacity(reduceMotion ? 0 : 1)
        .onAppear { go = true }
    }
}

// MARK: - 7. Fin

struct DoneStep: View {
    @EnvironmentObject var core: CoreModel
    let reduceMotion: Bool
    @State private var shown = false

    var body: some View {
        let s = core.state
        VStack(spacing: 28) {
            EchoLogo(size: 84, animated: !reduceMotion)
                .reveal(shown, delay: 0, reduceMotion: reduceMotion)
            VStack(spacing: 12) {
                Text(tr("Tout est prêt.", "All set.")).display(36)
                Text(tr("Diktation vit dans la barre des menus. Fermez cette fenêtre quand vous voulez : le raccourci reste actif.",
                        "Diktation lives in the menu bar. Close this window whenever you like: the shortcut stays active."))
                    .body(14).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
            }
            .reveal(shown, delay: 0.1, reduceMotion: reduceMotion)
            HStack(spacing: 10) {
                recap(chord: s.chord_label, title: tr("Maintenir", "Hold"), detail: tr("pour dicter", "to dictate"))
                recap(chord: s.chord_label + " ×2", title: tr("Double appui", "Double tap"), detail: tr("mains libres", "hands-free"))
                recap(chord: "esc", title: tr("Annuler", "Cancel"), detail: tr("rien n'est collé", "nothing is pasted"))
            }
            .reveal(shown, delay: 0.2, reduceMotion: reduceMotion)
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { shown = true } }
    }

    private func recap(chord: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ChordView(label: chord)
            Text(title).body(12.5, weight: .medium).foregroundStyle(Ink.primary)
            Text(detail).body(11.5).foregroundStyle(Ink.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.paper))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ink.hairline, lineWidth: 0.8))
    }
}
