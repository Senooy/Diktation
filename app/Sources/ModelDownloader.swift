// Téléchargement d'un modèle whisper (ggml) depuis le catalogue du cœur.
//
// Singleton observable : le téléchargement continue pendant que l'utilisateur
// avance dans l'accueil. Le fichier arrive dans un fichier temporaire, n'est
// installé que si sa taille est exactement celle du catalogue et qu'il
// commence par la signature ggml (« lmgg »), puis le cœur recharge le modèle.
// Annulation et reprise passent par les données de reprise d'URLSession.

import AppKit
import Foundation

final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    enum Phase: Equatable {
        case idle
        case downloading
        case verifying
        case done
        case failed(String)
        case cancelled

        var isActive: Bool { self == .downloading || self == .verifying }
    }

    /// Modèle en cours (ou dernier traité).
    @Published private(set) var model: CatalogModel?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var received: Int64 = 0
    @Published private(set) var total: Int64 = 0
    /// Octets par seconde (fenêtre glissante de ~3 s), 0 tant qu'inconnu.
    @Published private(set) var speed: Double = 0
    /// Secondes restantes estimées, nil tant qu'inconnu.
    @Published private(set) var eta: TimeInterval?

    var progress: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    var isActive: Bool { phase.isActive }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "dev.local.diktation.download"
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    private var installDir: URL?
    /// Vrai quand l'annulation vient de l'utilisateur (et non d'une erreur).
    private var cancelling = false
    /// Une reprise refusée par le serveur relance une fois depuis le début.
    private var resumedAttempt = false
    private var samples: [(Date, Int64)] = []
    private var lastPublish = Date.distantPast
    private var smoothedEta: Double?

    /// Marge d'espace libre exigée au-delà de la taille du modèle.
    private let margin: Int64 = 200_000_000

    private override init() { super.init() }

    // MARK: - Commandes

    /// Lance (ou relance) le téléchargement de `model` vers `dir`.
    func start(_ model: CatalogModel, into dir: String) {
        guard !isActive else { return }
        let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
        if self.model?.file != model.file { resumeData = nil }
        self.model = model
        installDir = dirURL
        received = 0
        total = model.bytes
        speed = 0
        eta = nil
        samples = []
        smoothedEta = nil
        cancelling = false

        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            phase = .failed(tr("Impossible de créer le dossier des modèles : \(error.localizedDescription)",
                               "Could not create the models folder: \(error.localizedDescription)"))
            return
        }
        if let free = freeSpace(at: dirURL), free < model.bytes + margin {
            phase = .failed(tr("Espace disque insuffisant : \(Self.format(bytes: model.bytes + margin)) nécessaires, \(Self.format(bytes: free)) disponibles.",
                               "Not enough disk space: \(Self.format(bytes: model.bytes + margin)) needed, \(Self.format(bytes: free)) available."))
            return
        }
        guard let url = URL(string: model.url) else {
            phase = .failed(tr("Adresse de téléchargement invalide.", "Invalid download address."))
            return
        }

        phase = .downloading
        let t: URLSessionDownloadTask
        if let data = resumeData {
            resumedAttempt = true
            resumeData = nil
            t = session.downloadTask(withResumeData: data)
        } else {
            resumedAttempt = false
            var request = URLRequest(url: url)
            request.setValue("Diktation/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
            t = session.downloadTask(with: request)
        }
        task = t
        t.resume()
    }

    /// Relance le dernier modèle (reprend là où il s'était arrêté si possible).
    func retry() {
        guard let model, let dir = installDir?.path else { return }
        start(model, into: dir)
    }

    /// Arrête le téléchargement en gardant de quoi reprendre.
    func cancel() {
        guard phase == .downloading, let task else { return }
        cancelling = true
        task.cancel { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                self.resumeData = data
                self.task = nil
                self.speed = 0
                self.eta = nil
                self.phase = .cancelled
            }
        }
    }

    /// Oublie le dernier téléchargement (après une réussite ou un abandon).
    func reset() {
        guard !isActive else { return }
        phase = .idle
        model = nil
        received = 0
        total = 0
        speed = 0
        eta = nil
        resumeData = nil
    }

    // MARK: - Délégué URLSession (file série, hors du fil principal)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        samples.append((now, totalBytesWritten))
        samples.removeAll { now.timeIntervalSince($0.0) > 3 }
        // Cinq à dix mises à jour par seconde suffisent à l'interface.
        guard now.timeIntervalSince(lastPublish) > 0.15 else { return }
        lastPublish = now

        var rate: Double = 0
        if let first = samples.first, now.timeIntervalSince(first.0) > 0.4 {
            rate = Double(totalBytesWritten - first.1) / now.timeIntervalSince(first.0)
        }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (model?.bytes ?? 0)
        var remaining: Double?
        if rate > 1, expected > totalBytesWritten {
            let raw = Double(expected - totalBytesWritten) / rate
            smoothedEta = smoothedEta.map { $0 * 0.7 + raw * 0.3 } ?? raw
            remaining = smoothedEta
        }
        DispatchQueue.main.async {
            guard self.phase == .downloading else { return }
            self.received = totalBytesWritten
            if expected > 0 { self.total = expected }
            self.speed = rate
            self.eta = remaining
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
                    expectedTotalBytes: Int64) {
        DispatchQueue.main.async {
            self.received = fileOffset
            if expectedTotalBytes > 0 { self.total = expectedTotalBytes }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Le fichier temporaire disparaît au retour de cette méthode : tout
        // se fait ici, de façon synchrone.
        guard let model, let installDir else { return }
        DispatchQueue.main.sync { self.phase = .verifying }
        let fm = FileManager.default
        let part = installDir.appendingPathComponent(".\(model.file).part")
        let final = installDir.appendingPathComponent(model.file)
        let result: Result<Void, InstallError>
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw InstallError(tr("Le serveur a répondu \(http.statusCode).", "The server answered \(http.statusCode)."))
            }
            try? fm.removeItem(at: part)
            try fm.moveItem(at: location, to: part)
            let size = (try fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard size == model.bytes else {
                throw InstallError(tr("Fichier incomplet (\(Self.format(bytes: max(0, size))) sur \(Self.format(bytes: model.bytes))).",
                                      "Incomplete file (\(Self.format(bytes: max(0, size))) of \(Self.format(bytes: model.bytes)))."))
            }
            guard let handle = try? FileHandle(forReadingFrom: part),
                  let head = try? handle.read(upToCount: 4), head == Data("lmgg".utf8) else {
                throw InstallError(tr("Ce fichier n'est pas un modèle whisper (signature ggml absente).",
                                      "This file is not a whisper model (ggml signature missing)."))
            }
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: part, to: final)
            // Le fichier temporaire d'URLSession est en 0600 : lisible comme
            // les autres modèles.
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: final.path)
            result = .success(())
        } catch let e as InstallError {
            try? fm.removeItem(at: part)
            result = .failure(e)
        } catch {
            try? fm.removeItem(at: part)
            result = .failure(InstallError(error.localizedDescription))
        }
        DispatchQueue.main.async {
            self.task = nil
            self.speed = 0
            self.eta = nil
            switch result {
            case .success:
                self.received = model.bytes
                self.total = model.bytes
                self.resumeData = nil
                self.phase = .done
                Task { @MainActor in
                    // `set_prefs` recharge déjà le moteur quand le modèle change ;
                    // sinon on le demande explicitement. Un seul chargement.
                    let core = CoreModel.shared
                    if core.state.prefs.model == model.file {
                        core.send("reload_model")
                    } else {
                        core.setPref("model", model.file)
                    }
                }
            case .failure(let e):
                self.phase = .failed(e.message)
            }
        }
    }

    /// Erreur d'installation (message déjà traduit).
    private struct InstallError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // la réussite passe par didFinishDownloadingTo
        let ns = error as NSError
        let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        DispatchQueue.main.async {
            self.task = nil
            self.speed = 0
            self.eta = nil
            if self.cancelling { return } // déjà traité dans cancel()
            if let data { self.resumeData = data }
            // Reprise refusée (fichier changé, serveur sans Range…) : on repart
            // une fois de zéro sans rien demander.
            if self.resumedAttempt, data == nil, let model = self.model, let dir = self.installDir?.path {
                self.resumedAttempt = false
                self.phase = .idle
                self.start(model, into: dir)
                return
            }
            let message: String
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorTimedOut:
                message = tr("Connexion interrompue. Vérifiez votre accès à Internet, puis reprenez.",
                             "Connection lost. Check your Internet access, then resume.")
            default:
                message = error.localizedDescription
            }
            self.phase = .failed(message)
        }
    }

    // MARK: - Utilitaires

    private func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// « 1,62 Go » / « 1.62 GB », « 574 Mo » / « 574 MB ».
    static func format(bytes: Int64) -> String {
        let f = NumberFormatter()
        f.locale = L10n.locale
        f.minimumFractionDigits = 0
        if bytes >= 1_000_000_000 {
            f.maximumFractionDigits = 2
            let v = Double(bytes) / 1_000_000_000
            return (f.string(from: NSNumber(value: v)) ?? String(v)) + tr(" Go", " GB")
        }
        f.maximumFractionDigits = 0
        let v = Double(bytes) / 1_000_000
        return (f.string(from: NSNumber(value: v)) ?? String(v)) + tr(" Mo", " MB")
    }

    /// « 12,4 Mo/s ».
    static func format(speed: Double) -> String {
        let f = NumberFormatter()
        f.locale = L10n.locale
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        let v = speed / 1_000_000
        return (f.string(from: NSNumber(value: v)) ?? String(v)) + tr(" Mo/s", " MB/s")
    }

    /// « 25 s restantes », « environ 3 min restantes ».
    static func format(eta: TimeInterval) -> String {
        if eta < 60 {
            let s = max(1, Int(eta.rounded()))
            return tr("\(s) s restantes", "\(s) s left")
        }
        let m = Int((eta / 60).rounded())
        if m < 60 { return tr("environ \(m) min restantes", "about \(m) min left") }
        let h = Int((eta / 3600).rounded())
        return tr("environ \(h) h restantes", "about \(h) h left")
    }
}
