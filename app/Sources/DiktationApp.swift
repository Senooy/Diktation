// Point d'entrée : fenêtre principale, icône de barre des menus, cœur Rust.

import AppKit
import SwiftUI

@main
struct DiktationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var core = CoreModel.shared

    var body: some Scene {
        Window("Diktation", id: "main") {
            // Premier lancement : l'accueil remplace la fenêtre principale,
            // qui apparaît en fondu quand il est terminé.
            ZStack {
                if core.isOnboarded {
                    MainView()
                        .transition(.opacity.combined(with: .scale(scale: 1.02)))
                } else {
                    OnboardingView()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.spring(response: 0.6, dampingFraction: 0.9), value: core.isOnboarded)
            .environmentObject(core)
            .font(BrandFont.text(13))
            .tint(Ink.indigo)
            // Icône du Dock tant que la fenêtre est ouverte ; fermée, l'app
            // ne vit plus que dans la barre des menus (LSUIElement au départ).
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .appInfo) { UpdateMenuButton().environmentObject(core) }
        }

        MenuBarExtra {
            MenuContent().environmentObject(core)
        } label: {
            Image(nsImage: EchoGlyph.image(busy: core.state.busy))
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var core: CoreModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = core.state
        if let id = s.meetings.recording_id {
            Text(tr("Réunion en cours · \(s.meetings.elapsed / 60) min", "Meeting recording · \(s.meetings.elapsed / 60) min"))
            Button(tr("Terminer la réunion", "Finish meeting")) { core.send("meeting_stop", ["id": id]) }
        } else if s.meetings.processing_id != nil {
            Text(tr("Finalisation de la réunion…", "Finalizing meeting…"))
        } else {
        Text(s.engine.ready ? tr("Prêt · maintenir \(s.chord_label) pour dicter", "Ready · hold \(s.chord_label) to dictate") : s.engine.status)
        }
        Divider()
        Button(tr("Ouvrir Diktation", "Open Diktation")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(tr("Recoller la dernière dictée", "Paste last dictation")) { core.send("paste_last") }
            .disabled(s.history.isEmpty)
        if let last = s.history.first, !last.text.isEmpty {
            Button(tr("Copier la dernière dictée", "Copy last dictation")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(last.text, forType: .string)
            }
        }
        Divider()
        UpdateMenuButton().environmentObject(core)
        Button(tr("Quitter Diktation", "Quit Diktation")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var finishingMeeting = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            CoreModel.shared.start()
            AppUpdates.shared.observeApplication()
        }
    }

    /// Finish and save an active meeting before allowing a normal app quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MeetingCapture.shared.cancelPreparation()
        CoreModel.shared.refresh()
        let meetings = CoreModel.shared.state.meetings
        guard meetings.recording_id != nil || meetings.processing_id != nil else { return .terminateNow }
        guard !finishingMeeting else { return .terminateLater }
        finishingMeeting = true
        if let id = meetings.recording_id { CoreModel.shared.send("meeting_stop", ["id": id]) }
        Task { @MainActor in
            // Give the core time to publish the stop command before checking completion.
            repeat {
                try? await Task.sleep(for: .milliseconds(250))
            } while CoreModel.shared.state.meetings.recording_id != nil || CoreModel.shared.state.meetings.processing_id != nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Fermer la fenêtre ne quitte pas : le raccourci reste actif.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Glyphe « Écho » de la barre des menus : barre centrale et anneau (deux
/// pendant une dictée). Image modèle : macOS la teinte selon le thème.
enum EchoGlyph {
    private static var cache: [Bool: NSImage] = [:]

    static func image(busy: Bool) -> NSImage {
        if let image = cache[busy] { return image }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 7.6, y: 3.5, width: 2.8, height: 11), xRadius: 1.4, yRadius: 1.4).fill()
            NSColor.black.withAlphaComponent(busy ? 0.9 : 0.55).setStroke()
            let ring = NSBezierPath(roundedRect: NSRect(x: 4.4, y: 1.2, width: 9.2, height: 15.6), xRadius: 4.6, yRadius: 4.6)
            ring.lineWidth = 1.4
            ring.stroke()
            if busy {
                NSColor.black.withAlphaComponent(0.45).setStroke()
                let outer = NSBezierPath(roundedRect: NSRect(x: 1.2, y: 0.4, width: 15.6, height: 17.2), xRadius: 7.8, yRadius: 7.8)
                outer.lineWidth = 1.1
                outer.stroke()
            }
            return true
        }
        image.isTemplate = true
        cache[busy] = image
        return image
    }
}
