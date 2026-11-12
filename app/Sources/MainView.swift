// Fenêtre principale : barre latérale sur fond crème, pages sur fond blanc.

import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, meetings, history, dictionary, snippets, style, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: tr("Accueil", "Home")
        case .meetings: tr("Réunions", "Meetings")
        case .history: tr("Historique", "History")
        case .dictionary: tr("Dictionnaire", "Dictionary")
        case .snippets: tr("Raccourcis vocaux", "Voice shortcuts")
        case .style: tr("Style", "Style")
        case .settings: tr("Réglages", "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .meetings: "person.3.sequence"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "character.book.closed"
        case .snippets: "text.bubble"
        case .style: "wand.and.stars"
        case .settings: "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var core: CoreModel
    @State private var page: Page = .home
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Ink.hairline).frame(width: 0.8)
            if page == .meetings {
                MeetingsPage(openSettings: { select(.settings) }).background(Ink.paper)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch page {
                        case .home: HomePage(go: select)
                        case .meetings: EmptyView()
                        case .history: HistoryPage()
                        case .dictionary: DictionaryPage()
                        case .snippets: SnippetsPage()
                        case .style: StylePage()
                        case .settings: SettingsPage()
                        }
                    }
                    .id(page)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                    .frame(maxWidth: 920, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 36)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Ink.paper)
            }
        }
        .frame(minWidth: page == .meetings ? 1080 : 940, minHeight: 680)
        .ignoresSafeArea()
        .preferredColorScheme(.light)
    }

    private func select(_ p: Page) {
        guard p != page else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { page = p }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                BrandGlyph(size: 32)
                Text("Diktation").font(BrandFont.text(20, weight: .bold)).tracking(-0.8)
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, 10)
            .padding(.top, 46)
            .padding(.bottom, 18)

            Text(tr("VOTRE ESPACE", "YOUR SPACE")).body(9, weight: .bold).tracking(1.2)
                .foregroundStyle(Ink.muted).padding(.horizontal, 12).padding(.vertical, 12)
            ForEach([Page.home, .meetings, .history]) { p in
                SidebarRow(page: p, selected: page == p, namespace: selection) { select(p) }
            }
            Text(tr("À VOTRE MAIN", "MAKE IT YOURS")).body(9, weight: .bold).tracking(1.2)
                .foregroundStyle(Ink.muted).padding(.horizontal, 12).padding(.top, 30).padding(.bottom, 12)
            ForEach([Page.dictionary, .snippets, .style, .settings]) { p in
                SidebarRow(page: p, selected: page == p, namespace: selection) { select(p) }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    StatusDot(ok: core.state.engine.ready && core.state.hotkey_active && core.state.accessibility)
                    Text(core.state.meetings.recording_id != nil ? tr("Réunion en cours", "Meeting recording") : core.state.meetings.processing_id != nil ? tr("Finalisation…", "Finalizing…") : core.state.engine.ready ? tr("Prêt", "Ready") : tr("Démarrage…", "Starting…")).body(11.5).foregroundStyle(Ink.secondary)
                }
                Text(tr("Vos mots restent sur ce Mac.", "Your words stay on this Mac.")).body(11).foregroundStyle(Ink.muted)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 10)
        .frame(width: 208)
        .background(Ink.canvas.opacity(0.65))
    }
}

struct SidebarRow: View {
    let page: Page
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .symbolEffect(.bounce, value: selected)
                Text(page.label).body(13, weight: selected ? .medium : .regular)
                Spacer()
            }
            .foregroundStyle(selected ? Ink.primary : (hovered ? Ink.primary.opacity(0.8) : Ink.secondary))
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Ink.lavender.opacity(0.8))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Ink.hairline, lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovered {
                    RoundedRectangle(cornerRadius: 13).fill(Ink.hairline.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h } }
    }
}

/// Bouton sans décor qui s'enfonce légèrement.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.pressable(configuration.isPressed)
    }
}

// MARK: - Accueil

struct HomePage: View {
    @EnvironmentObject var core: CoreModel
    let go: (Page) -> Void
    @State private var showPractice = false

    var body: some View {
        let s = core.state
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(tr("Un peu de voix. Beaucoup de possibilités.", "A little voice. A lot of possibility.")).body(12).foregroundStyle(Ink.secondary)
                Spacer()
                HStack(spacing: 6) {
                    StatusDot(ok: s.engine.ready && s.accessibility && s.hotkey_active)
                    Text(s.engine.ready && s.accessibility && s.hotkey_active ? tr("Tout est prêt", "Ready when you are") : tr("Configuration en cours", "Getting ready")).body(11)
                }.foregroundStyle(Ink.secondary)
            }
            hero(s)
            if !s.accessibility || s.fn_conflict || s.last_error != nil || s.engine.failed {
                warnings(s)
            }
            HStack(alignment: .top, spacing: 16) {
                actionCard(symbol: "waveform", title: tr("Dicter un texte", "Dictate a thought"),
                           detail: tr("Un message, un mail, une idée.\nParlez, les mots suivent.", "A message, an email, an idea.\nSpeak and the words follow."),
                           action: tr("Essayer la dictée", "Try dictation"), tint: Ink.lavender) { showPractice = true }
                actionCard(symbol: "person.2", title: tr("Garder une réunion", "Capture a meeting"),
                           detail: tr("Les échanges transcrits.\nVos notes juste à côté.", "The conversation, transcribed.\nYour notes right alongside."),
                           action: s.meetings.recording_id != nil || s.meetings.processing_id != nil ? tr("Revenir à la réunion", "Return to meeting") : tr("Préparer une réunion", "Prepare a meeting"), tint: Color(hex: 0xF3E3E9)) {
                    if s.meetings.recording_id == nil && s.meetings.processing_id == nil { core.send("meeting_create") }
                    go(.meetings)
                }
            }
            if let last = s.history.first, !last.text.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionHeader(title: tr("Vos derniers mots", "Your latest words"))
                        Spacer()
                        Button(tr("Tout retrouver", "See everything")) { go(.history) }.buttonStyle(QuietButtonStyle())
                    }
                    Card {
                        Text(last.text).body(13).foregroundStyle(Ink.primary).lineLimit(3).textSelection(.enabled)
                        Text(last.date.formatted(date: .abbreviated, time: .shortened))
                            .body(11).foregroundStyle(Ink.secondary).padding(.top, 8)
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                Text(tr("Sur votre Mac. Sans compte. À votre rythme.", "On your Mac. No account. At your own pace."))
                Spacer()
                if s.stats.count > 0 { Text(tr("\(s.stats.count) dictées · \(s.stats.words) mots", "\(s.stats.count) dictations · \(s.stats.words) words")) }
            }.body(10.5).foregroundStyle(Ink.secondary)
        }
        .sheet(isPresented: $showPractice) { DictationPractice().environmentObject(core) }
    }

    private func hero(_ s: AppState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Tag(text: tr("La voix, tout simplement", "Simply your voice"))
            VStack(alignment: .leading, spacing: -2) {
                Text(tr("Moins de clavier.", "Less typing.")).display(43)
                Text(tr("Plus de liberté.", "More freedom.")).font(BrandFont.text(43, weight: .bold)).tracking(-1.7).foregroundStyle(Ink.indigo)
            }
            Text(tr("Dictez vos idées. Gardez le fil de vos réunions.\nDiktation s’occupe des mots, vous du reste.", "Dictate your ideas. Keep track of your meetings.\nDiktation takes care of the words. You do the rest."))
                .body(14).foregroundStyle(Ink.primary.opacity(0.8)).lineSpacing(3)
            HStack(spacing: 10) {
                ChordView(label: s.chord_label)
                Text(tr("Maintenez, parlez, relâchez. C’est écrit.", "Hold, speak, release. It’s written.")).body(12, weight: .medium)
            }.padding(.top, 8)
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        .background(AuroraBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 26))
    }

    private func actionCard(symbol: String, title: String, detail: String, action: String, tint: Color, run: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(Ink.primary)
                .frame(width: 48, height: 48).background(tint, in: RoundedRectangle(cornerRadius: 16))
            Text(title).display(23)
            Text(detail).body(12.5).foregroundStyle(Ink.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Button(action: run) {
                HStack { Text(action); Spacer(minLength: 4); Image(systemName: "arrow.right") }
            }.buttonStyle(BlackButtonStyle()).padding(.top, 5)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Ink.hairline, lineWidth: 0.7))
    }

    @ViewBuilder
    private func warnings(_ s: AppState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !s.accessibility {
                notice(tr("Diktation a besoin de l'Accessibilité pour le raccourci global et le collage.", "Diktation needs Accessibility access for the global shortcut and pasting."),
                       action: tr("Autoriser", "Allow")) { core.send("prompt_accessibility") }
            }
            if s.engine.failed {
                notice(s.engine.status, action: tr("Réglages", "Settings")) { go(.settings) }
            }
            if s.fn_conflict && s.chord_label.contains("fn") {
                notice(tr("La touche fn ouvre aussi un outil macOS. Réglages Système → Clavier → « Touche 🌐 » : choisir « Ne rien faire ».", "The fn key also opens a macOS tool. System Settings → Keyboard → “Press 🌐 key to”: choose “Do Nothing”."),
                       action: nil, run: {})
            }
            if let err = s.last_error {
                notice(err, action: "OK") { core.send("dismiss_error") }
            }
        }
    }

    private func notice(_ text: String, action: String?, run: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Ink.coral)
            Text(text).body(12.5).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action { Button(action, action: run).buttonStyle(BlackButtonStyle()) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.coral.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.coral.opacity(0.25), lineWidth: 0.8))
    }

}

// MARK: - Historique

struct HistoryPage: View {
    @EnvironmentObject var core: CoreModel
    @State private var query = ""
    @State private var copied: Int64?
    @State private var confirmClear = false

    var body: some View {
        let entries = core.state.history.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Historique", "History")).display(30)
                    Text(tr("Gardé sur ce Mac uniquement.", "Kept on this Mac only.")).body(13).foregroundStyle(Ink.secondary)
                }
                Spacer()
                if !core.state.history.isEmpty {
                    Button(tr("Tout effacer", "Clear all")) { confirmClear = true }.buttonStyle(QuietButtonStyle(destructive: true))
                }
            }
            Field(placeholder: tr("Rechercher dans les dictées", "Search dictations"), text: $query)
            if entries.isEmpty {
                Card {
                    Text(query.isEmpty ? tr("Aucune dictée pour l'instant. Maintenez \(core.state.chord_label) dans n'importe quelle app.", "No dictations yet. Hold \(core.state.chord_label) in any app.")
                         : tr("Aucun résultat.", "No results."))
                        .body(13).foregroundStyle(Ink.secondary)
                }
            }
            ForEach(groups(entries), id: \.0) { day, items in
                VStack(alignment: .leading, spacing: 8) {
                    Text(day.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(Ink.muted)
                    Card(padding: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                            if i > 0 { Divider().overlay(Ink.hairline) }
                            HistoryRow(entry: e, copied: copied == e.id, canRetranscribe: core.state.engine.ready) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(e.text, forType: .string)
                                withAnimation(.snappy) { copied = e.id }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                    if copied == e.id { withAnimation(.snappy) { copied = nil } }
                                }
                            }
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity.combined(with: .scale(scale: 0.98))))
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: entries.map(\.id))
        .alert(tr("Effacer tout l'historique ?", "Clear the whole history?"), isPresented: $confirmClear) {
            Button(tr("Effacer", "Clear"), role: .destructive) { core.send("clear_history") }
            Button(tr("Annuler", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("Les textes et l'audio enregistrés seront supprimés de ce Mac.", "Saved texts and audio will be deleted from this Mac."))
        }
    }

    private func groups(_ entries: [HistoryEntry]) -> [(String, [HistoryEntry])] {
        let cal = Calendar.current
        var out: [(String, [HistoryEntry])] = []
        for e in entries {
            let label: String
            if cal.isDateInToday(e.date) { label = tr("Aujourd'hui", "Today") }
            else if cal.isDateInYesterday(e.date) { label = tr("Hier", "Yesterday") }
            else { label = e.date.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
            if out.last?.0 == label { out[out.count - 1].1.append(e) } else { out.append((label, [e])) }
        }
        return out
    }
}

struct HistoryRow: View {
    @EnvironmentObject var core: CoreModel
    let entry: HistoryEntry
    let copied: Bool
    let canRetranscribe: Bool
    let copy: () -> Void
    @State private var hovered = false
    @State private var showSpeakers = true

    var body: some View {
        let e = entry
        HStack(alignment: .top, spacing: 14) {
            Text(e.date.formatted(date: .omitted, time: .shortened))
                .body(11.5).foregroundStyle(Ink.muted).frame(width: 44, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(e.text.isEmpty ? tr("(vide)", "(empty)") : e.text).body(13.5).foregroundStyle(Ink.primary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if core.state.analysis_id == e.id || core.state.retranscribing_id == e.id {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(core.state.analysis_id == e.id ? tr("Analyse des intervenants…", "Analyzing speakers…") : tr("Transcription…", "Transcribing…")).body(12)
                    }
                }
                if !e.turns.isEmpty {
                    DisclosureGroup(tr("Intervenants · \(Set(e.turns.map(\.speaker)).count)", "Speakers · \(Set(e.turns.map(\.speaker)).count)"), isExpanded: $showSpeakers) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(e.turns.enumerated()), id: \.offset) { _, turn in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(turn.time) · \(turn.label)" + (turn.overlap ? tr(" · voix superposées", " · overlapping voices") : ""))
                                        .body(11).foregroundStyle(Ink.muted)
                                    Text(turn.text.isEmpty ? tr("Parole non transcrite", "Speech not transcribed") : turn.text)
                                        .body(13).textSelection(.enabled)
                                }
                            }
                            Button(tr("Copier avec les intervenants", "Copy with speakers")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(e.turns.map { "[\($0.time)] \($0.label): \($0.text)" }.joined(separator: "\n\n"), forType: .string)
                            }.buttonStyle(QuietButtonStyle())
                        }.padding(.top, 8)
                    }
                }
                Text([e.app, String(format: "%.1f s", e.seconds), "\(e.millis) ms"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .body(11).foregroundStyle(Ink.muted)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button(action: copy) {
                    Label(copied ? tr("Copié", "Copied") : tr("Copier", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .contentTransition(.symbolEffect(.replace))
                }
                if e.has_audio && canRetranscribe {
                    Button { core.send("retranscribe", ["id": e.id]) } label: { Image(systemName: "arrow.clockwise") }
                        .help(tr("Re-transcrire depuis l'audio", "Re-transcribe from the audio"))
                        .disabled(core.state.busy || core.state.analysis_id != nil || core.state.retranscribing_id != nil)
                    Menu {
                        Button(tr("Détecter automatiquement", "Detect automatically")) { core.send("analyze_speakers", ["id": e.id]) }
                        ForEach(1...8, id: \.self) { count in
                            Button(tr("\(count) intervenant(s)", "\(count) speaker(s)")) {
                                core.send("analyze_speakers", ["id": e.id, "speakers": count])
                            }
                        }
                    } label: { Image(systemName: "person.2.wave.2") }
                        .help(core.state.speakers_ready ? tr("Identifier les intervenants", "Identify speakers") : tr("Installez les modèles d’intervenants dans les réglages", "Install speaker models in Settings"))
                        .disabled(!core.state.speakers_ready || core.state.busy || core.state.analysis_id != nil || core.state.retranscribing_id != nil)
                }
                Button { core.send("delete", ["id": e.id]) } label: { Image(systemName: "trash") }
                    .help(tr("Supprimer", "Delete"))
            }
            .buttonStyle(QuietButtonStyle())
            // Les actions apparaissent au survol (restent si « Copié »).
            .opacity(hovered || copied ? 1 : 0)
            .offset(x: hovered || copied ? 0 : 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(hovered ? Ink.canvas.opacity(0.7) : .clear)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hovered = h } }
    }
}

// MARK: - Dictionnaire

struct DictionaryPage: View {
    @EnvironmentObject var core: CoreModel
    @State private var word = ""
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        let prefs = core.state.prefs
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Dictionnaire", "Dictionary")).display(30)
                Text(tr("Noms propres, marques et jargon : soufflés à whisper avant chaque dictée pour qu'il les écrive juste.", "Names, brands and jargon: whispered to the model before each dictation so it spells them right."))
                    .body(13).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: tr("Vocabulaire", "Vocabulary"))
                HStack(spacing: 8) {
                    Field(placeholder: tr("Ajouter un mot…", "Add a word…"), text: $word, onSubmit: addWord)
                    Button(tr("Ajouter", "Add"), action: addWord).buttonStyle(BlackButtonStyle())
                }
                FlowLayout {
                    ForEach(prefs.dictionary, id: \.self) { w in
                        HStack(spacing: 6) {
                            Text(w).body(12.5)
                            Button { core.setPref("dictionary", prefs.dictionary.filter { $0 != w }) } label: {
                                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                            }
                            .buttonStyle(.plain).foregroundStyle(Ink.muted)
                        }
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(Ink.canvas))
                        .overlay(Capsule().stroke(Ink.hairline, lineWidth: 0.8))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: prefs.dictionary)
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: tr("Corrections automatiques", "Automatic corrections"),
                              subtitle: tr("Quand whisper se trompe toujours de la même façon (« dictation » → « Diktation »).", "When whisper always gets a word wrong the same way (“dictation” → “Diktation”)."))
                HStack(spacing: 8) {
                    Field(placeholder: tr("Whisper écrit…", "Whisper writes…"), text: $from, onSubmit: addReplacement)
                    Image(systemName: "arrow.right").foregroundStyle(Ink.muted)
                    Field(placeholder: tr("Remplacer par…", "Replace with…"), text: $to, onSubmit: addReplacement)
                    Button(tr("Ajouter", "Add"), action: addReplacement).buttonStyle(BlackButtonStyle())
                }
                if !prefs.replacements.isEmpty {
                    Card(padding: 0) {
                        ForEach(Array(prefs.replacements.enumerated()), id: \.offset) { i, r in
                            if i > 0 { Divider().overlay(Ink.hairline) }
                            HStack(spacing: 10) {
                                Text(r.from).body(13).foregroundStyle(Ink.secondary)
                                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Ink.muted)
                                Text(r.to).body(13).foregroundStyle(Ink.primary)
                                Spacer()
                                Button {
                                    var list = prefs.replacements
                                    list.remove(at: i)
                                    core.setReplacements(list)
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(QuietButtonStyle())
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                        }
                    }
                }
            }
        }
    }

    private func addWord() {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        var list = core.state.prefs.dictionary
        if !list.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) { list.append(w) }
        core.setPref("dictionary", list)
        word = ""
    }

    private func addReplacement() {
        let f = from.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return }
        core.setReplacements(core.state.prefs.replacements + [Replacement(from: f, to: to.trimmingCharacters(in: .whitespaces))])
        from = ""
        to = ""
    }
}

// MARK: - Raccourcis vocaux

struct SnippetsPage: View {
    @EnvironmentObject var core: CoreModel
    @State private var trigger = ""
    @State private var text = ""

    var body: some View {
        let snippets = core.state.prefs.snippets
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Raccourcis vocaux", "Voice shortcuts")).display(30)
                Text(tr("Dites une phrase, Diktation insère le texte enregistré : adresse, signature, lien, modèle de réponse…", "Say a phrase and Diktation inserts the saved text: address, signature, link, canned reply…"))
                    .body(13).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("QUAND JE DIS", "WHEN I SAY")).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Ink.muted)
                    Field(placeholder: tr("mon adresse mail", "my email address"), text: $trigger)
                    Text(tr("INSÉRER", "INSERT")).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Ink.muted).padding(.top, 4)
                    TextEditor(text: $text)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 76)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Ink.paper))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.hairline, lineWidth: 0.8))
                    HStack {
                        Spacer()
                        Button(tr("Ajouter le raccourci", "Add shortcut"), action: add).buttonStyle(BlackButtonStyle())
                    }
                }
            }
            if !snippets.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: tr("Enregistrés", "Saved"))
                    Card(padding: 0) {
                        ForEach(Array(snippets.enumerated()), id: \.offset) { i, s in
                            if i > 0 { Divider().overlay(Ink.hairline) }
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tr("« \(s.trigger) »", "“\(s.trigger)”")).body(12.5, weight: .medium).foregroundStyle(Ink.indigo)
                                    Text(s.text).body(13).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Button {
                                    var list = snippets
                                    list.remove(at: i)
                                    core.setSnippets(list)
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(QuietButtonStyle())
                            }
                            .padding(16)
                        }
                    }
                }
            }
        }
    }

    private func add() {
        let t = trigger.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        core.setSnippets(core.state.prefs.snippets + [Snippet(trigger: t, text: text)])
        trigger = ""
        text = ""
    }
}

// MARK: - Style (Apple Intelligence)

struct StylePage: View {
    @EnvironmentObject var core: CoreModel

    var body: some View {
        let s = core.state
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Tag(text: tr("Apple Intelligence · sur le Mac", "Apple Intelligence · on this Mac"))
                Text(tr("Style", "Style")).display(30)
                Text(tr("Diktation met la dictée au propre selon l'app où vous écrivez. Le modèle d'Apple tourne sur ce Mac : rien n'est envoyé.", "Diktation cleans up your dictation for the app you're writing in. Apple's model runs on this Mac: nothing is sent."))
                    .body(13).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if (s.prefs.rewrite || s.prefs.command) && s.llm.state == "unavailable" {
                Card {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(Ink.coral)
                        Text(s.llm.reason).body(12.5).foregroundStyle(Ink.primary)
                    }
                }
            }
            Card(padding: 4) {
                ToggleRow(title: tr("Reformuler selon l'app", "Rewrite for each app"), hint: tr("Ton choisi par catégorie ci-dessous ; « Tel quel » colle la dictée brute", "Tone set per category below; “As is” pastes the raw dictation"),
                          isOn: s.prefs.rewrite) { core.setPref("rewrite", $0) }
                    .padding(.horizontal, 12)
            }
            VStack(spacing: 12) {
                ForEach(s.categories) { cat in
                    Card {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(cat.label).body(14, weight: .medium).foregroundStyle(Ink.primary)
                                Text(cat.examples).body(11.5).foregroundStyle(Ink.muted)
                            }
                            Spacer()
                            HStack(spacing: 5) {
                                ForEach(s.tones) { tone in
                                    Chip(label: tone.label, active: cat.tone == tone.id) {
                                        core.setTone(category: cat.id, tone: tone.id)
                                    }
                                }
                            }
                        }
                    }
                    .opacity(s.prefs.rewrite ? 1 : 0.45)
                    .disabled(!s.prefs.rewrite)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: tr("Mode commande", "Command mode"),
                              subtitle: tr("Sélectionnez du texte, maintenez le raccourci et dites quoi en faire (« rends ça plus poli », « traduis en anglais »). Sans sélection, Diktation rédige ce que vous demandez.", "Select text, hold the shortcut and say what to do with it (“make it more polite”, “translate to French”). With nothing selected, Diktation writes what you ask for."))
                Card(padding: 4) {
                    ToggleRow(title: tr("Activer le mode commande", "Enable command mode"), hint: tr("La sélection est remplacée par le résultat", "The selection is replaced by the result"),
                              isOn: s.prefs.command) { core.setPref("command", $0) }
                        .padding(.horizontal, 12)
                    Divider().overlay(Ink.hairline)
                    ChordRecorderRow(title: tr("Raccourci", "Shortcut"), label: s.command_chord_label, recording: s.recording_command,
                                     command: "record_command")
                        .padding(.horizontal, 12)
                        .opacity(s.prefs.command ? 1 : 0.45)
                        .disabled(!s.prefs.command)
                }
            }
        }
    }
}

struct ChordRecorderRow: View {
    @EnvironmentObject var core: CoreModel
    let title: String
    let label: String
    let recording: Bool
    let command: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).body(13).foregroundStyle(Ink.primary)
            Spacer()
            Group {
                if recording {
                    ListeningLabel()
                } else {
                    ChordView(label: label).transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: recording)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: label)
            Button(recording ? tr("Annuler", "Cancel") : tr("Modifier", "Change")) { core.send(command, ["on": !recording]) }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(.vertical, 10)
    }
}

/// « Appuyez sur les touches… » qui pulse pendant l'enregistrement d'un raccourci.
struct ListeningLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            Oscillator(period: 1.2, autoreverses: true) { phase in
                Circle().fill(Ink.indigo).frame(width: 6, height: 6).opacity(0.25 + 0.75 * phase)
            }
            Text(tr("Appuyez sur les touches…", "Press the keys…")).body(12).foregroundStyle(Ink.indigo)
        }
        .transition(.opacity)
    }
}

/// Choix du micro : celui du système ou un micro précis. La liste est relue
/// à l'ouverture de la page et sur demande (micro branché entre-temps).
struct MicrophonePicker: View {
    @EnvironmentObject var core: CoreModel

    var body: some View {
        let s = core.state
        let chosen = s.prefs.microphone
        let systemLabel = tr("Micro du système", "System microphone") + (s.default_microphone.map { " · \($0)" } ?? "")
        VStack(alignment: .leading, spacing: 0) {
            row(systemLabel, icon: "gearshape", selected: chosen.isEmpty) { core.setPref("microphone", "") }
            ForEach(s.microphones, id: \.self) { name in
                Divider().overlay(Ink.hairline)
                row(name, icon: icon(for: name), selected: chosen == name) { core.setPref("microphone", name) }
            }
            if !chosen.isEmpty && !s.microphones.isEmpty && !s.microphones.contains(chosen) {
                Divider().overlay(Ink.hairline)
                row(chosen + tr(" (débranché)", " (unplugged)"), icon: "mic.slash", selected: true, dimmed: true) {}
            }
            Divider().overlay(Ink.hairline)
            HStack {
                Spacer()
                Button(tr("Actualiser la liste", "Refresh list")) { core.send("list_mics") }
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(.vertical, 8)
        }
        .onAppear { core.send("list_mics") }
    }

    private func row(_ label: String, icon: String, selected: Bool, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18).foregroundStyle(Ink.secondary)
                Text(label).body(13).foregroundStyle(dimmed ? Ink.muted : Ink.primary).lineLimit(1)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.primary)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .animation(.snappy(duration: 0.2), value: selected)
    }

    private func icon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods") || n.contains("headphone") || n.contains("casque") || n.contains("beats") { return "headphones" }
        if n.contains("macbook") || n.contains("intégré") || n.contains("built-in") { return "laptopcomputer" }
        if n.contains("iphone") { return "iphone" }
        return "mic"
    }
}

/// Catalogue des modèles : choisir un modèle installé, ou en télécharger un
/// (un seul téléchargement à la fois, il continue si on change de page).
struct ModelPicker: View {
    @EnvironmentObject var core: CoreModel
    @ObservedObject private var downloader = ModelDownloader.shared

    var body: some View {
        let s = core.state
        let current = s.models.first(where: \.loaded)?.file ?? s.prefs.model
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(s.catalog.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Divider().overlay(Ink.hairline) }
                row(m, selected: m.installed && m.file == current, s: s)
            }
            Text(tr("Whisper tourne sur le GPU et suit le dictionnaire. Les autres modèles (sherpa-onnx, sur le processeur) ne lisent pas le dictionnaire : les corrections automatiques s'appliquent quand même.",
                    "Whisper runs on the GPU and follows the dictionary. The other models (sherpa-onnx, on the CPU) don't read the dictionary; automatic corrections still apply."))
                .body(11.5).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func row(_ m: CatalogModel, selected: Bool, s: AppState) -> some View {
        let downloading = downloader.model?.file == m.file && downloader.isActive
        let failed: String? = {
            if downloader.model?.file == m.file, case .failed(let msg) = downloader.phase { return msg }
            return nil
        }()
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : (m.installed ? "circle" : "arrow.down.circle"))
                .font(.system(size: 15))
                .foregroundStyle(selected ? Ink.primary : Ink.muted)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 3) {
                Text(m.label).body(13, weight: selected ? .medium : .regular).foregroundStyle(Ink.primary)
                if downloading {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: downloader.progress).progressViewStyle(.linear).tint(Ink.primary).frame(maxWidth: 260)
                        Text(downloader.phase == .verifying ? tr("Vérification et installation…", "Verifying and installing…")
                             : "\(ModelDownloader.format(bytes: downloader.received)) / \(ModelDownloader.format(bytes: downloader.total))"
                               + (downloader.speed > 0 ? " · " + ModelDownloader.format(speed: downloader.speed) : ""))
                            .body(11).foregroundStyle(Ink.muted)
                    }
                } else if let failed {
                    Text(failed).body(11).foregroundStyle(Ink.coral).lineLimit(2)
                } else {
                    Text([ModelDownloader.format(bytes: m.bytes),
                          m.supports_language ? nil : tr("ne prend pas en charge la langue choisie", "doesn't support the chosen language")]
                        .compactMap { $0 }.joined(separator: " · "))
                        .body(11).foregroundStyle(m.supports_language ? Ink.muted : Ink.coral)
                }
            }
            Spacer()
            if downloading {
                Button(tr("Pause", "Pause")) { downloader.cancel() }.buttonStyle(QuietButtonStyle())
            } else if m.installed {
                if !selected {
                    Button(tr("Utiliser", "Use")) { core.setPref("model", m.file) }.buttonStyle(QuietButtonStyle())
                }
            } else {
                Button(failed != nil || (downloader.model?.file == m.file && downloader.phase == .cancelled)
                       ? tr("Reprendre", "Resume") : tr("Télécharger", "Download")) {
                    if downloader.model?.file == m.file { downloader.retry() } else { downloader.start(m, into: s.install_dir) }
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(downloader.isActive)
            }
        }
        .padding(.vertical, 10)
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

// MARK: - Réglages

struct SettingsPage: View {
    @EnvironmentObject var core: CoreModel

    var body: some View {
        let s = core.state
        VStack(alignment: .leading, spacing: 28) {
            Text(tr("Réglages", "Settings")).display(30)

            group(tr("Mises à jour", "Updates")) { UpdateSettings() }

            group(tr("Raccourci", "Shortcut"), subtitle: tr("Modificateurs seuls : fn, ⌃, ⌥, ⌘, ⇧, ⌥ droite, ⌘ droite.", "Modifier keys only: fn, ⌃, ⌥, ⌘, ⇧, right ⌥, right ⌘.")) {
                ChordRecorderRow(title: tr("Dictée", "Dictation"), label: s.chord_label, recording: s.recording_chord, command: "record_chord")
            }

            group(tr("Micro", "Microphone"),
                  subtitle: tr("Si le micro choisi est débranché, Diktation utilise celui du système.",
                               "If the chosen microphone is unplugged, Diktation falls back to the system one.")) {
                MicrophonePicker()
            }

            group(tr("Langue", "Language")) {
                FlowLayout {
                    ForEach(s.languages) { l in
                        Chip(label: l.label, active: s.prefs.language == l.code) { core.setPref("language", l.code) }
                    }
                }
                .padding(.vertical, 10)
            }

            group(tr("Modèle de transcription", "Transcription model"), subtitle: s.engine.status) {
                ModelPicker()
                Divider().overlay(Ink.hairline)
                ToggleRow(title: tr("Décodage Whisper rapide", "Fast Whisper decoding"),
                          hint: tr("Réduit l’attente, avec un compromis possible sur la précision. Sans effet sur les autres modèles.", "Reduces latency, with a possible accuracy tradeoff. Other models are unaffected."),
                          isOn: s.prefs.fast_transcription) { core.setPref("fast_transcription", $0) }
            }

            group(tr("Intervenants", "Speakers"), subtitle: tr("Analyse locale à la demande depuis l’historique. Gardez l’audio pour l’utiliser. Les numéros sont propres à chaque enregistrement ; les voix superposées peuvent être imprécises.", "Local analysis on demand from History. Keep audio to use it. Numbers belong to each recording; overlapping speech can be inaccurate.")) {
                SpeakerModelsView()
            }

            group(tr("Texte", "Text")) {
                ToggleRow(title: tr("Retirer les hésitations", "Remove filler words"), hint: tr("« euh », « heu », « hum »…", "“um”, “uh”, “hmm”…"), isOn: s.prefs.remove_fillers) {
                    core.setPref("remove_fillers", $0)
                }
                Divider().overlay(Ink.hairline)
                ToggleRow(title: tr("Commandes vocales", "Voice commands"), hint: tr("« à la ligne », « nouveau paragraphe »", "“new line”, “new paragraph”"), isOn: s.prefs.voice_commands) {
                    core.setPref("voice_commands", $0)
                }
                Divider().overlay(Ink.hairline)
                ToggleRow(title: tr("Restaurer le presse-papiers", "Restore the clipboard"), hint: tr("Remet l'ancien contenu après le collage", "Puts the previous content back after pasting"),
                          isOn: s.prefs.restore_clipboard) { core.setPref("restore_clipboard", $0) }
            }

            group(tr("Confidentialité et sons", "Privacy and sounds")) {
                ToggleRow(title: tr("Sons", "Sounds"), hint: tr("Petit son au début et à la fin", "A short sound at start and end"), isOn: s.prefs.sounds) { core.setPref("sounds", $0) }
                Divider().overlay(Ink.hairline)
                ToggleRow(title: tr("Garder l'audio", "Keep audio"), hint: tr("Permet de re-transcrire depuis l'historique", "Lets you re-transcribe from the history"), isOn: s.prefs.keep_audio) {
                    core.setPref("keep_audio", $0)
                }
                Divider().overlay(Ink.hairline)
                ToggleRow(title: tr("Suppression automatique", "Auto-delete"), hint: tr("Efface l'historique et l'audio de plus de 24 h", "Deletes history and audio older than 24 h"),
                          isOn: s.prefs.auto_delete) { core.setPref("auto_delete", $0) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Données : \(s.data_dir)", "Data: \(s.data_dir)")).body(11.5).foregroundStyle(Ink.muted).textSelection(.enabled)
                Text(tr("Modèles cherchés dans : ", "Models are looked up in: ") + s.model_dirs.joined(separator: " · ")).body(11.5).foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    private func group<Content: View>(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, subtitle: subtitle)
            Card(padding: 4) {
                VStack(alignment: .leading, spacing: 0) { content() }.padding(.horizontal, 12)
            }
        }
    }
}
