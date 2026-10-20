// Pont vers le cœur Rust (src/ffi.rs) : état décodé, commandes, pastille.

import AppKit
import Foundation

// MARK: - État envoyé par le cœur

struct HistoryEntry: Decodable, Identifiable, Equatable {
    let id: Int64
    let at: Int64
    let text: String
    let app: String
    let seconds: Double
    let millis: Int64
    let has_audio: Bool

    var date: Date { Date(timeIntervalSince1970: TimeInterval(at)) }
}

struct Stats: Decodable, Equatable {
    let count: Int
    let words: Int
    let seconds: Double
}

struct EngineState: Decodable, Equatable {
    let ready: Bool
    let failed: Bool
    let status: String
}

struct LlmState: Decodable, Equatable {
    let state: String
    let reason: String
}

struct ModelFile: Decodable, Equatable, Identifiable {
    let file: String
    let label: String
    let loaded: Bool
    var id: String { file }
}

struct Language: Decodable, Equatable, Identifiable {
    let code: String
    let label: String
    var id: String { code }
}

struct CategoryInfo: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let examples: String
    let tone: String
}

/// Modèle téléchargeable (catalogue du cœur).
struct CatalogModel: Decodable, Equatable, Identifiable {
    let file: String
    let label: String
    let bytes: Int64
    let url: String
    let recommended: Bool
    let installed: Bool
    var id: String { file }
}

struct ToneInfo: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
}

struct Snippet: Codable, Equatable, Hashable {
    var trigger: String
    var text: String
}

struct Replacement: Codable, Equatable, Hashable {
    var from: String
    var to: String
}

/// Réglages, lus pour l'affichage. L'écriture passe par `CoreModel.setPref`
/// sur le JSON brut, pour ne jamais perdre un champ que Swift ne connaît pas.
struct Prefs: Decodable, Equatable {
    var language: String = "fr"
    var model: String = ""
    var dictionary: [String] = []
    var replacements: [Replacement] = []
    var snippets: [Snippet] = []
    var remove_fillers = true
    var voice_commands = true
    var sounds = true
    var keep_audio = true
    var auto_delete = false
    var restore_clipboard = true
    var rewrite = true
    var command = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func get<T: Decodable>(_ k: Key, _ d: T) -> T { (try? c.decode(T.self, forKey: k)) ?? d }
        language = get(.language, "fr")
        model = get(.model, "")
        dictionary = get(.dictionary, [])
        replacements = get(.replacements, [])
        snippets = get(.snippets, [])
        remove_fillers = get(.remove_fillers, true)
        voice_commands = get(.voice_commands, true)
        sounds = get(.sounds, true)
        keep_audio = get(.keep_audio, true)
        auto_delete = get(.auto_delete, false)
        restore_clipboard = get(.restore_clipboard, true)
        rewrite = get(.rewrite, true)
        command = get(.command, true)
    }

    enum Key: String, CodingKey {
        case language, model, dictionary, replacements, snippets, remove_fillers, voice_commands, sounds,
             keep_audio, auto_delete, restore_clipboard, rewrite, command
    }
}

struct AppState: Decodable, Equatable {
    var prefs = Prefs()
    var chord_label = "fn"
    var command_chord_label = "fn + ⌃"
    var history: [HistoryEntry] = []
    var stats = Stats(count: 0, words: 0, seconds: 0)
    var engine = EngineState(ready: false, failed: false, status: tr("Démarrage…", "Starting…"))
    var accessibility = true
    var hotkey_active = false
    var fn_conflict = false
    var llm = LlmState(state: "unknown", reason: "")
    var recording_chord = false
    var recording_command = false
    var last_error: String?
    var busy = false
    var models: [ModelFile] = []
    var catalog: [CatalogModel] = []
    var install_dir = ""
    var audio_started = false
    var model_dirs: [String] = []
    var data_dir = ""
    var languages: [Language] = []
    var categories: [CategoryInfo] = []
    var tones: [ToneInfo] = []
}

struct PillState: Decodable, Equatable {
    var visible = false
    var mode = "listening"
    var hands_free = false
    var command = false
    var secs = 0
    var message = ""
    var levels: [Double] = Array(repeating: 0, count: 18)
    var bundle_id = ""
}

// MARK: - Modèle observé par l'interface

@MainActor
final class CoreModel: ObservableObject {
    static let shared = CoreModel()

    @Published private(set) var state = AppState()
    @Published private(set) var pill = PillState()
    /// Reflet observable de `CoreModel.onboarded` : la fenêtre bascule de
    /// l'accueil à la fenêtre principale quand il passe à vrai.
    @Published private(set) var isOnboarded = CoreModel.onboarded
    private var rawPrefs: [String: Any] = [:]

    private init() {}

    /// Accueil terminé (premier lancement fait).
    static var onboarded: Bool {
        get { UserDefaults.standard.bool(forKey: "onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "onboarded") }
    }

    /// Dernière étape de l'accueil : mémorise et révèle la fenêtre principale.
    func finishOnboarding() {
        CoreModel.onboarded = true
        isOnboarded = true
    }

    func start() {
        // Langue du cœur, et autorisations retenues tant que l'accueil n'est
        // pas terminé (il les demande à l'étape qui les explique).
        setenv("DIKTATION_LANG", L10n.code, 1)
        setenv("DIKTATION_ONBOARDING", CoreModel.onboarded ? "0" : "1", 1)
        _ = dk_start({ event, _ in
            guard let event else { return }
            let data = Data(bytes: event, count: strlen(event))
            Task { @MainActor in CoreModel.shared.handle(data) }
        }, nil)
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "changed":
            refresh()
        case "pill":
            if let p = try? JSONDecoder().decode(PillState.self, from: data) {
                // 30 événements par seconde pendant l'écoute : publier chacun
                // redessinerait toute la fenêtre. Seul l'essai de l'accueil
                // affiche les niveaux en direct ; ailleurs, on ne publie que
                // les changements de mode.
                if !isOnboarded || p.visible != pill.visible || p.mode != pill.mode || p.hands_free != pill.hands_free
                    || p.command != pill.command || p.message != pill.message || p.bundle_id != pill.bundle_id {
                    pill = p
                }
                PillPanel.shared.update(p)
            }
        default:
            break
        }
    }

    func refresh() {
        guard let ptr = dk_state() else { return }
        defer { dk_free(ptr) }
        let data = Data(bytes: ptr, count: strlen(ptr))
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let prefs = obj["prefs"] as? [String: Any] {
            rawPrefs = prefs
        }
        if let s = try? JSONDecoder().decode(AppState.self, from: data), s != state {
            state = s
        }
    }

    // MARK: Commandes

    func send(_ cmd: String, _ args: [String: Any] = [:]) {
        var payload = args
        payload["cmd"] = cmd
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { dk_send($0) }
    }

    /// Change un réglage et renvoie l'ensemble au cœur.
    func setPref(_ key: String, _ value: Any) {
        rawPrefs[key] = value
        send("set_prefs", ["prefs": rawPrefs])
    }

    func setTone(category: String, tone: String) {
        var tones = rawPrefs["tones"] as? [String: Any] ?? [:]
        tones[category] = tone
        setPref("tones", tones)
    }

    func setSnippets(_ list: [Snippet]) {
        setPref("snippets", list.map { ["trigger": $0.trigger, "text": $0.text] })
    }

    func setReplacements(_ list: [Replacement]) {
        setPref("replacements", list.map { ["from": $0.from, "to": $0.to] })
    }
}
