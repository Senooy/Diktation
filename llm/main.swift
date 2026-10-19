// diktation-llm : pont entre Diktation (Rust) et le modèle de langage
// d'Apple Intelligence (framework FoundationModels, sur l'appareil). Rien ne
// quitte le Mac.
//
// Protocole : une ligne JSON par message, requêtes sur stdin, réponses sur
// stdout, traitées l'une après l'autre.
//
//   {"id":1,"op":"status"}
//     → {"id":1,"available":true}  ou  {"id":1,"available":false,"reason":"…"}
//   {"op":"prewarm","instructions":"…"}            (pas de réponse)
//     charge le modèle et prépare une session pendant que l'utilisateur parle
//   {"id":2,"op":"respond","instructions":"…","prompt":"…","max_tokens":800}
//     → {"id":2,"text":"…"}  ou  {"id":2,"error":"…"}

import Foundation
import FoundationModels

/// Langue héritée de l'app (DIKTATION_LANG) : français ou anglais.
let french = ProcessInfo.processInfo.environment["DIKTATION_LANG"]?.hasPrefix("fr") ?? false
func tr(_ fr: String, _ en: String) -> String { french ? fr : en }

struct Request: Decodable {
    let id: Int?
    let op: String
    let instructions: String?
    let prompt: String?
    let max_tokens: Int?
}

// Garde-fous « transformation de contenu » : on réécrit le texte que
// l'utilisateur vient de dicter, pas une demande ouverte.
let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

/// Session préparée par `prewarm`, servie à la requête suivante qui a les
/// mêmes instructions (une session garde son historique : une seule
/// utilisation).
var warm: (instructions: String, session: LanguageModelSession)?

func reply(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          var line = String(data: data, encoding: .utf8) else { return }
    line += "\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}

func unavailableReason() -> String? {
    switch model.availability {
    case .available:
        return nil
    case .unavailable(.appleIntelligenceNotEnabled):
        return tr("Apple Intelligence est désactivé (Réglages Système → Apple Intelligence et Siri)", "Apple Intelligence is turned off (System Settings → Apple Intelligence & Siri)")
    case .unavailable(.deviceNotEligible):
        return tr("Ce Mac ne prend pas en charge Apple Intelligence", "This Mac doesn't support Apple Intelligence")
    case .unavailable(.modelNotReady):
        return tr("Le modèle d'Apple Intelligence est en cours de téléchargement", "The Apple Intelligence model is still downloading")
    case .unavailable(let other):
        return tr("Apple Intelligence indisponible", "Apple Intelligence unavailable") + " (\(other))"
    }
}

func describe(_ error: Error) -> String {
    if let e = error as? LanguageModelError {
        switch e {
        case .contextSizeExceeded: return tr("texte trop long pour le modèle", "text too long for the model")
        case .guardrailViolation: return tr("refusé par les garde-fous d'Apple", "blocked by Apple's guardrails")
        case .unsupportedLanguageOrLocale: return tr("langue non prise en charge", "language not supported")
        case .rateLimited: return tr("modèle occupé, réessayer", "model busy, try again")
        case .timeout: return tr("le modèle n'a pas répondu à temps", "the model did not answer in time")
        case .refusal: return tr("le modèle a refusé", "the model refused")
        default: break
        }
    }
    return "\(error)"
}

func respond(_ req: Request) async {
    let instructions = req.instructions ?? ""
    let session: LanguageModelSession
    if let w = warm, w.instructions == instructions {
        session = w.session
    } else {
        session = LanguageModelSession(model: model, instructions: instructions)
    }
    warm = nil
    let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: req.max_tokens ?? 800)
    do {
        let r = try await session.respond(to: req.prompt ?? "", options: options)
        reply(["id": req.id ?? 0, "text": r.content])
    } catch {
        reply(["id": req.id ?? 0, "error": describe(error)])
    }
}

func handle(_ req: Request) async {
    switch req.op {
    case "status":
        var out: [String: Any] = ["id": req.id ?? 0, "available": unavailableReason() == nil]
        if let reason = unavailableReason() { out["reason"] = reason }
        reply(out)
    case "prewarm":
        guard unavailableReason() == nil else { return }
        let instructions = req.instructions ?? ""
        let session = LanguageModelSession(model: model, instructions: instructions)
        session.prewarm()
        warm = (instructions, session)
    case "respond":
        await respond(req)
    default:
        reply(["id": req.id ?? 0, "error": "opération inconnue : \(req.op)"])
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let decoder = JSONDecoder()
while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8), let req = try? decoder.decode(Request.self, from: data) else {
        continue
    }
    let done = DispatchSemaphore(value: 0)
    // L'utilisateur attend la réponse pour voir son texte collé.
    Task(priority: .userInitiated) {
        await handle(req)
        done.signal()
    }
    done.wait()
}
