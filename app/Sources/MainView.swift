// Fenêtre principale : barre latérale sur fond crème, pages sur fond blanc.

import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, history, dictionary, snippets, style, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: tr("Accueil", "Home")
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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch page {
                    case .home: HomePage(go: select)
                    case .history: HistoryPage()
                    case .dictionary: DictionaryPage()
                    case .snippets: SnippetsPage()
                    case .style: StylePage()
                    case .settings: SettingsPage()
                    }
                }
                .id(page)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 36)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Ink.paper)
        }
        .frame(minWidth: 820, minHeight: 560)
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
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 22, height: 22)
                Text("Diktation").font(.system(size: 17, weight: .regular)).tracking(-0.4)
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, 10)
            .padding(.top, 46)
            .padding(.bottom, 18)

            ForEach(Page.allCases) { p in
                SidebarRow(page: p, selected: page == p, namespace: selection) { select(p) }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    StatusDot(ok: core.state.engine.ready && core.state.hotkey_active && core.state.accessibility)
                    Text(core.state.engine.ready ? tr("Prêt", "Ready") : tr("Démarrage…", "Starting…")).body(11.5).foregroundStyle(Ink.secondary)
                }
                Text(tr("100 % local · whisper.cpp", "100% local · whisper.cpp")).body(11).foregroundStyle(Ink.muted)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 10)
        .frame(width: 216)
        .background(Ink.canvas)
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
            .frame(height: 32)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Ink.paper)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Ink.hairline, lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovered {
                    RoundedRectangle(cornerRadius: 7).fill(Ink.hairline.opacity(0.5))
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
    @State private var heroIn = false

    var body: some View {
        let s = core.state
        VStack(alignment: .leading, spacing: 28) {
            hero(s)
                .onAppear { withAnimation(.easeOut(duration: 0.6)) { heroIn = true } }
            if !s.accessibility || s.fn_conflict || s.last_error != nil || s.engine.failed {
                warnings(s).transition(.opacity.combined(with: .move(edge: .top)))
            }
            stats(s)
            status(s)
            if let last = s.history.first, !last.text.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: tr("Dernière dictée", "Last dictation"))
                    Card {
                        Text(last.text).body(13.5).foregroundStyle(Ink.primary).textSelection(.enabled)
                            .id(last.id)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                        Text("\(last.app.isEmpty ? "" : last.app + " · ")\(last.date.formatted(date: .omitted, time: .shortened))")
                            .body(11.5).foregroundStyle(Ink.muted).padding(.top, 8)
                    }
                }
            }
        }
    }

    private func hero(_ s: AppState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Tag(text: tr("Dictée locale", "Local dictation"))
            Text(tr("Parlez naturellement,\nDiktation écrit.", "Speak naturally,\nDiktation writes.")).display(34).lineSpacing(2)
            Text(tr("Maintenez le raccourci dans n'importe quelle app, parlez, relâchez : le texte apparaît là où est votre curseur. Rien ne quitte ce Mac.", "Hold the shortcut in any app, speak, let go: the text appears where your cursor is. Nothing leaves this Mac."))
                .body(14).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                gesture(chord: s.chord_label, text: tr("Maintenir pour dicter", "Hold to dictate"))
                gesture(chord: s.chord_label + " ×2", text: tr("Mains libres", "Hands-free"))
                gesture(chord: "esc", text: tr("Annuler", "Cancel"))
                if s.prefs.command {
                    gesture(chord: s.command_chord_label, text: tr("Commande", "Command"))
                }
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Lavis qui glisse doucement à l'arrivée sur la page.
            RoundedRectangle(cornerRadius: 16).fill(
                LinearGradient(colors: [Ink.mint, Color(hex: 0xF6F4FB), Ink.lavender],
                               startPoint: heroIn ? .topLeading : .leading,
                               endPoint: heroIn ? .bottomTrailing : .trailing)
            )
        )
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Ink.hairline, lineWidth: 0.8))
    }

    private func gesture(chord: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ChordView(label: chord)
            Text(text).body(11.5).foregroundStyle(Ink.secondary)
        }
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

    private func stats(_ s: AppState) -> some View {
        // ~40 mots/min au clavier contre ~150 à l'oral.
        let saved = max(0, Double(s.stats.words) / 40 - s.stats.seconds / 60)
        return HStack(spacing: 12) {
            stat(value: "\(s.stats.count)", label: tr("dictées", "dictations"))
            stat(value: s.stats.words.formatted(), label: tr("mots écrits à la voix", "words written by voice"))
            stat(value: saved < 60 ? "\(Int(saved)) min" : String(format: "%.1f h", saved / 60), label: tr("gagnées sur le clavier", "saved vs. typing"))
        }
    }

    private func stat(value: String, label: String) -> some View {
        Card {
            Text(value).display(28)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.4), value: value)
            Text(label).body(12).foregroundStyle(Ink.secondary).padding(.top, 2)
        }
    }

    private func status(_ s: AppState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: tr("État", "Status"))
            Card(padding: 0) {
                statusRow(ok: s.engine.ready, title: tr("Transcription", "Transcription"), detail: s.engine.status)
                Divider().overlay(Ink.hairline)
                statusRow(ok: s.accessibility && s.hotkey_active, title: tr("Raccourci global", "Global shortcut"),
                          detail: s.accessibility ? (s.hotkey_active ? tr("Actif", "Active") : tr("Démarrage…", "Starting…")) : tr("Accessibilité requise", "Accessibility required"))
                if s.prefs.rewrite || s.prefs.command {
                    Divider().overlay(Ink.hairline)
                    statusRow(ok: s.llm.state == "ready", title: "Apple Intelligence",
                              detail: s.llm.state == "ready" ? tr("Prêt (style et mode commande)", "Ready (style and command mode)")
                                  : (s.llm.state == "unknown" ? tr("Vérification…", "Checking…") : s.llm.reason))
                }
            }
        }
    }

    private func statusRow(ok: Bool, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            StatusDot(ok: ok)
            Text(title).body(13).foregroundStyle(Ink.primary)
            Spacer()
            Text(detail).body(12).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
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

    var body: some View {
        let e = entry
        HStack(alignment: .top, spacing: 14) {
            Text(e.date.formatted(date: .omitted, time: .shortened))
                .body(11.5).foregroundStyle(Ink.muted).frame(width: 44, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(e.text.isEmpty ? tr("(vide)", "(empty)") : e.text).body(13.5).foregroundStyle(Ink.primary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Réglages

struct SettingsPage: View {
    @EnvironmentObject var core: CoreModel

    var body: some View {
        let s = core.state
        VStack(alignment: .leading, spacing: 28) {
            Text(tr("Réglages", "Settings")).display(30)

            group(tr("Raccourci", "Shortcut"), subtitle: tr("Modificateurs seuls : fn, ⌃, ⌥, ⌘, ⇧, ⌥ droite, ⌘ droite.", "Modifier keys only: fn, ⌃, ⌥, ⌘, ⇧, right ⌥, right ⌘.")) {
                ChordRecorderRow(title: tr("Dictée", "Dictation"), label: s.chord_label, recording: s.recording_chord, command: "record_chord")
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
                FlowLayout {
                    ForEach(s.models) { m in
                        Chip(label: m.label, active: s.prefs.model == m.file || m.loaded) { core.setPref("model", m.file) }
                    }
                }
                .padding(.vertical, 10)
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
