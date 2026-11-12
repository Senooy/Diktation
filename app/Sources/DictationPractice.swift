import AppKit
import SwiftUI

/// A real text field for the existing global dictation shortcut. No simulated transcript.
struct DictationPractice: View {
    @EnvironmentObject var core: CoreModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                BrandGlyph()
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(QuietButtonStyle()).accessibilityLabel(tr("Fermer l’essai", "Close practice"))
            }
            Text(tr("À vous la parole.", "Over to you.")).display(32)
            HStack(spacing: 10) {
                ChordView(label: core.state.chord_label)
                Text(tr("Maintenez pour parler. Relâchez pour écrire.", "Hold to speak. Release to write.")).body(13)
            }
            Text(tr("Cliquez dans le champ et essayez une phrase. Le même geste fonctionne dans vos autres apps.", "Click the field and try a sentence. The same shortcut works in your other apps."))
                .body(13).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            if core.state.meetings.recording_id != nil || core.state.meetings.processing_id != nil {
                Text(tr("Terminez la réunion avant d’essayer la dictée.", "Finish your meeting before trying dictation.")).body(12).foregroundStyle(Ink.coral)
            } else if !core.state.accessibility {
                Button(tr("Autoriser le raccourci dans Accessibilité", "Allow the shortcut in Accessibility")) { core.send("prompt_accessibility") }
                    .buttonStyle(BlackButtonStyle())
            } else if !core.state.engine.ready {
                Text(core.state.engine.status).body(12).foregroundStyle(Ink.coral)
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(tr("Par exemple : « On se retrouve demain à dix heures. »", "For example: “Let’s meet tomorrow at ten.”"))
                        .body(14).foregroundStyle(Ink.muted).padding(14).allowsHitTesting(false)
                }
                TextEditor(text: $text).font(BrandFont.text(15)).lineSpacing(4)
                    .scrollContentBackground(.hidden).padding(8).focused($focused)
                    .accessibilityLabel(tr("Champ d’essai de dictée", "Dictation practice field"))
            }.frame(height: 140).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Ink.indigo.opacity(focused ? 0.5 : 0.12), lineWidth: 1))
            HStack {
                Text(tr("Astuce : deux appuis pour dicter les mains libres.", "Tip: press twice for hands-free dictation.")).body(11).foregroundStyle(Ink.secondary)
                Spacer()
                Button(tr("Compris !", "Got it!")) { dismiss() }.buttonStyle(BlackButtonStyle())
            }
        }.padding(32).frame(width: 570).background(AuroraBackdrop()).preferredColorScheme(.light)
            .onAppear { focused = true }
    }
}
