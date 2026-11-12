import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingsPage: View {
    @EnvironmentObject var core: CoreModel
    @State private var selected: Int64 = 0
    var openSettings: () -> Void = {}

    var body: some View {
        let meetings = core.state.meetings
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Réunions", "Meetings")).display(30)
                    Text(tr("Les échanges d’un côté, vos idées de l’autre.", "The conversation alongside your own thoughts."))
                        .body(13).foregroundStyle(Ink.secondary)
                }
                Spacer()
                if !meetings.items.isEmpty {
                    Button { core.send("meeting_create") } label: {
                        Label(tr("Nouvelle réunion", "New meeting"), systemImage: "plus")
                    }.buttonStyle(BlackButtonStyle())
                }
            }
            if let error = meetings.error {
                Text(error).body(12).foregroundStyle(Ink.coral).textSelection(.enabled)
            }
            if meetings.items.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "person.2.wave.2").font(.system(size: 42, weight: .light)).foregroundStyle(Ink.indigo)
                    Text(tr("Écoutez vraiment.\nRetrouvez chaque idée.", "Be in the conversation.\nKeep every idea.")).display(36).multilineTextAlignment(.center)
                    Text(tr("En présentiel ou en visio : les échanges transcrits,\nles intervenants repérés, vos notes à côté.", "In person or on a call: a transcript,\nidentified speakers, and room for your notes."))
                        .body(14).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                    Button { core.send("meeting_create") } label: {
                        Label(tr("Préparer ma première réunion", "Prepare my first meeting"), systemImage: "plus")
                    }.buttonStyle(BlackButtonStyle())
                    Text(tr("L’enregistrement ne commence que lorsque vous le décidez.", "Recording only starts when you choose.")).body(11).foregroundStyle(Ink.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AuroraBackdrop()).clipShape(RoundedRectangle(cornerRadius: 26))
            } else {
                Picker(tr("Réunion", "Meeting"), selection: $selected) {
                    ForEach(meetings.items) { m in
                        Text("\(m.title) · \(m.date.formatted(date: .abbreviated, time: .shortened))").tag(m.id)
                    }
                }.labelsHidden()
                if let meeting = meetings.items.first(where: { $0.id == selected }) {
                    if meeting.detail_loaded {
                        MeetingEditor(meeting: meeting, openSettings: openSettings).id(meeting.id)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { selectDefault() }
        .onChange(of: selected) { _, id in if id > 0 { core.send("meeting_select", ["id": id]) } }
        .onChange(of: meetings.selected_id) { _, id in if let id { selected = id } }
        .onChange(of: meetings.items.map(\.id)) { _, _ in selectDefault() }
    }

    private func selectDefault() {
        let state = core.state.meetings
        if !state.items.contains(where: { $0.id == selected }) {
            selected = state.selected_id ?? state.recording_id ?? state.items.first?.id ?? 0
        }
    }
}

struct MeetingEditor: View {
    @EnvironmentObject var core: CoreModel
    let meeting: MeetingEntry
    var openSettings: () -> Void
    @State private var title: String
    @State private var notes: String
    @State private var names: [String: String]
    @State private var count: Int
    @State private var source = "microphone"
    @ObservedObject private var capture = MeetingCapture.shared
    @State private var confirmDelete = false
    @State private var exportError: String?
    @State private var copied = false

    init(meeting: MeetingEntry, openSettings: @escaping () -> Void = {}) {
        self.meeting = meeting
        self.openSettings = openSettings
        _title = State(initialValue: meeting.title)
        _notes = State(initialValue: meeting.notes)
        _names = State(initialValue: meeting.names)
        _count = State(initialValue: meeting.speaker_count)
        _source = State(initialValue: meeting.source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField(tr("Titre de la réunion", "Meeting title"), text: $title)
                .textFieldStyle(.plain).font(BrandFont.text(24, weight: .bold)).foregroundStyle(Ink.primary)
                .onChange(of: title) { _, value in edit(["title": value]) }
            if meeting.status == "draft" {
                HStack(spacing: 12) {
                    sourceChoice("microphone", symbol: "person.2", title: tr("Autour de la table", "In the same room"), detail: tr("Le micro capte les échanges.", "The microphone captures everyone."))
                    sourceChoice("microphone_system", symbol: "laptopcomputer", title: tr("En visioconférence", "On a video call"), detail: tr("Votre micro + le son du Mac.", "Your microphone + Mac audio."))
                }.disabled(capture.preparingID != nil)
                if source == "microphone_system" {
                    Text(tr("Enregistre aussi le son des autres apps du Mac. Utilisez un casque pour éviter l’écho.", "Also records audio from other Mac apps. Use headphones to avoid echo."))
                        .body(11.5).foregroundStyle(Ink.secondary)
                }
            }
            if let error = capture.error { Text(error).body(12).foregroundStyle(Ink.coral).textSelection(.enabled) }
            controls
            if meeting.status == "draft" && (!core.state.speakers_ready || !core.state.engine.ready) {
                HStack {
                    Text(tr("Encore une étape : préparez les modèles dans les réglages.", "One more step: prepare the models in Settings.")).body(12).foregroundStyle(Ink.secondary)
                    Spacer()
                    Button(tr("Configurer", "Set up"), action: openSettings).buttonStyle(QuietButtonStyle())
                }
            }
            if !meeting.error.isEmpty {
                Text(meeting.error).body(12).foregroundStyle(Ink.coral).textSelection(.enabled)
            }
            if let exportError { Text(exportError).body(12).foregroundStyle(Ink.coral) }
            HStack(alignment: .top, spacing: 18) {
                transcript.frame(maxWidth: .infinity, maxHeight: .infinity)
                notesPane.frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                    copied = true
                } label: { Label(copied ? tr("Copié", "Copied") : tr("Copier", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                Button(tr("Exporter .md", "Export .md")) { export() }
                Spacer()
                Text(tr("Conservé sur ce Mac · audio inclus", "Saved on this Mac · includes audio"))
                    .body(11).foregroundStyle(Ink.muted)
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .disabled(meeting.status == "recording" || meeting.status == "processing")
                    .help(tr("Supprimer la réunion et son audio", "Delete meeting and audio"))
            }.buttonStyle(QuietButtonStyle())
        }
        .frame(maxHeight: .infinity)
        .onChange(of: notes) { _, value in edit(["notes": value]) }
        .onChange(of: names) { _, value in edit(["names": value]) }
        .alert(tr("Supprimer cette réunion ?", "Delete this meeting?"), isPresented: $confirmDelete) {
            Button(tr("Supprimer", "Delete"), role: .destructive) { core.send("meeting_delete", ["id": meeting.id]) }
            Button(tr("Annuler", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("Les notes, la transcription et l’audio seront supprimés.", "Notes, transcript and audio will be deleted."))
        }
    }

    private func sourceChoice(_ value: String, symbol: String, title: String, detail: String) -> some View {
        Button { source = value } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 21)).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).body(13, weight: .semibold)
                    Text(detail).body(11).foregroundStyle(Ink.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: source == value ? "checkmark.circle.fill" : "circle").foregroundStyle(source == value ? Ink.indigo : Ink.muted)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Ink.primary)
                .background(source == value ? Ink.lavender.opacity(0.65) : Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(source == value ? Ink.indigo.opacity(0.4) : Ink.hairline, lineWidth: 1))
        }.buttonStyle(PressStyle()).accessibilityAddTraits(source == value ? .isSelected : [])
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if meeting.status == "draft" {
                Button { core.send("meeting_start", ["id": meeting.id, "speakers": count, "source": source]) } label: {
                    Label(capture.preparingID == meeting.id ? tr("Autorisation / préparation…", "Permission / preparing…") : tr("Enregistrer", "Record"), systemImage: "record.circle")
                }.buttonStyle(BlackButtonStyle())
                    .disabled(capture.preparingID != nil || core.state.busy || !core.state.engine.ready || !core.state.speakers_ready || core.state.analysis_id != nil || core.state.retranscribing_id != nil)
                Picker(tr("Intervenants", "Speakers"), selection: $count) {
                    Text(tr("Nombre automatique", "Automatic count")).tag(0)
                    ForEach(1...8, id: \.self) { n in Text(tr("\(n) intervenant(s)", "\(n) speaker(s)")).tag(n) }
                }.labelsHidden().frame(width: 180)
            } else if meeting.status == "recording" {
                Button { core.send("meeting_stop", ["id": meeting.id]) } label: {
                    Label(tr("Terminer", "Finish"), systemImage: "stop.fill")
                }.buttonStyle(BlackButtonStyle()).disabled(capture.stoppingID == meeting.id)
                Circle().fill(Ink.coral).frame(width: 8, height: 8)
                Text(duration(core.state.meetings.elapsed)).monospacedDigit().body(14, weight: .medium)
                if meeting.source == "microphone_system" {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(tr("Micro", "Mic")).frame(width: 30); ProgressView(value: capture.levels[0]).frame(width: 50) }
                        HStack { Text("Mac").frame(width: 30); ProgressView(value: capture.levels[1]).frame(width: 50) }
                    }.body(10).foregroundStyle(Ink.secondary)
                }
            } else if meeting.status == "processing" {
                ProgressView().controlSize(.small)
                Text(meeting.statusLabel).body(12).foregroundStyle(Ink.indigo)
            } else {
                Text(meeting.statusLabel).body(12).foregroundStyle(Ink.secondary)
                Button(tr("Re-transcrire", "Transcribe again")) { core.send("meeting_retry", ["id": meeting.id]) }
                    .buttonStyle(QuietButtonStyle()).disabled(core.state.busy || !core.state.engine.ready || !core.state.speakers_ready)
            }
            Spacer(minLength: 0)
            if meeting.status == "draft" || meeting.status == "recording" {
                VStack(alignment: .trailing, spacing: 2) {
                    Text((meeting.status == "draft" ? source : meeting.source) == "microphone_system" ? tr("Micro + son du Mac", "Microphone + Mac audio") : (core.state.prefs.microphone.isEmpty ? tr("Microphone par défaut", "Default microphone") : core.state.prefs.microphone))
                    Text(tr("Jusqu’à 60 min", "Up to 60 min"))
                }.body(11).foregroundStyle(Ink.secondary)
            }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(tr("Transcription", "Transcript"), systemImage: "waveform").body(14, weight: .semibold)
                Spacer()
                if meeting.status == "recording" { Tag(text: tr("En direct", "Live")) }
            }
            Text(meeting.status == "recording"
                 ? tr("Texte provisoire par passages de 5 s. Les intervenants sont identifiés à la fin.", "Provisional text in 5-second passages. Speakers are identified at the end.")
                 : tr("Prises de parole horodatées. Vous pouvez nommer chaque intervenant.", "Timestamped turns. You can name each speaker."))
                .body(11.5).foregroundStyle(Ink.secondary)
            if !speakerIDs.isEmpty {
                ForEach(speakerIDs, id: \.self) { speaker in
                    HStack {
                        Circle().fill(speakerColor(speaker)).frame(width: 7, height: 7)
                        TextField(tr("Intervenant \(speaker)", "Speaker \(speaker)"), text: Binding(
                            get: { names[String(speaker)] ?? "" },
                            set: { names[String(speaker)] = $0 }
                        )).textFieldStyle(.plain).body(12)
                    }
                }
            }
            Divider().overlay(Ink.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if meeting.turns.isEmpty {
                        Text(meeting.status == "draft"
                             ? tr("La transcription apparaîtra ici pendant la réunion. Vous pouvez déjà préparer vos notes à droite.", "The transcript will appear here during the meeting. You can prepare notes on the right now.")
                             : meeting.status == "ready" ? tr("Aucune parole détectée.", "No speech detected.")
                             : tr("À l’écoute des échanges… Vos notes restent disponibles à droite.", "Listening to the conversation… Your notes are available on the right."))
                            .body(13).foregroundStyle(Ink.muted).padding(.top, 20)
                    }
                    ForEach(Array(meeting.turns.enumerated()), id: \.offset) { _, turn in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(turn.time).monospacedDigit().foregroundStyle(Ink.muted)
                                Text(speakerLabel(turn.speaker)).foregroundStyle(speakerColor(turn.speaker))
                                if turn.overlap { Image(systemName: "person.2").help(tr("Voix superposées : attribution à vérifier", "Overlapping voices: check attribution")) }
                            }.body(11, weight: .medium)
                            Text(turn.text.isEmpty ? tr("Parole non transcrite", "Speech not transcribed") : turn.text)
                                .body(14).lineSpacing(4).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.78)))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Ink.hairline, lineWidth: 0.8))
    }

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("Mes notes", "My notes"), systemImage: "square.and.pencil").body(14, weight: .semibold)
            Text(tr("Idées, décisions, questions à reprendre…", "Ideas, decisions, questions to revisit…"))
                .body(11.5).foregroundStyle(Ink.secondary)
            Divider().overlay(Ink.hairline)
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text(tr("Écrivez librement pendant les échanges.\n\n• Points importants\n• Décisions\n• Actions à suivre", "Write freely during the conversation.\n\n• Key points\n• Decisions\n• Next steps"))
                        .body(14).foregroundStyle(Ink.muted).padding(.horizontal, 5).padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $notes).font(BrandFont.text(14)).lineSpacing(5)
                    .scrollContentBackground(.hidden).accessibilityLabel(tr("Mes notes de réunion", "My meeting notes"))
            }
            Text(meeting.notes == notes ? tr("Enregistré sur ce Mac", "Saved on this Mac") : tr("Enregistrement…", "Saving…"))
                .body(10.5).foregroundStyle(Ink.muted)
        }.padding(20)
            .background(RoundedRectangle(cornerRadius: 22).fill(Ink.lavender.opacity(0.32)))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Ink.hairline, lineWidth: 0.8))
    }

    private var speakerIDs: [Int] { Array(Set(meeting.turns.map(\.speaker).filter { $0 > 0 })).sorted() }
    private func speakerColor(_ id: Int) -> Color { [Ink.indigo, Ink.fresh, Ink.coral][max(0, id - 1) % 3] }
    private func speakerLabel(_ id: Int) -> String {
        if id == 0 { return tr("Provisoire", "Provisional") }
        let name = names[String(id)]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? tr("Intervenant \(id)", "Speaker \(id)") : name
    }
    private func duration(_ seconds: Int) -> String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }
    private func edit(_ fields: [String: Any]) {
        var payload = fields; payload["id"] = meeting.id
        core.send("meeting_edit", payload)
        copied = false
    }
    private var markdown: String {
        let turns = meeting.turns.map { "[\($0.time)] **\(speakerLabel($0.speaker))**" + ($0.overlap ? tr(" (voix superposées)", " (overlapping voices)") : "") + "\n\n\($0.text)" }.joined(separator: "\n\n")
        return "# \(title)\n\n\(meeting.date.formatted(date: .long, time: .shortened))\n\n## \(tr("Transcription", "Transcript"))\n\n\(turns)\n\n## \(tr("Mes notes", "My notes"))\n\n\(notes)\n"
    }
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "reunion-\(meeting.id).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try markdown.write(to: url, atomically: true, encoding: .utf8); exportError = nil }
        catch { exportError = error.localizedDescription }
    }
}
