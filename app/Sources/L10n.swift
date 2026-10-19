// Langue de l'interface : français si le Mac est en français, anglais sinon.
// Les textes sont écrits par paires à l'endroit où ils servent :
// `tr("Historique", "History")`. Le cœur Rust reçoit la même langue par la
// variable DIKTATION_LANG (voir CoreModel.start).

import Foundation

enum L10n {
    static let isFrench: Bool = Locale.preferredLanguages.first?.lowercased().hasPrefix("fr") ?? false
    static var code: String { isFrench ? "fr" : "en" }
    static var locale: Locale { Locale(identifier: isFrench ? "fr_FR" : "en_US") }
}

/// Texte selon la langue de l'interface.
func tr(_ fr: String, _ en: String) -> String {
    L10n.isFrench ? fr : en
}
