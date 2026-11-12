import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdates()
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var automaticDownloads = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var error: String?
    @Published private(set) var waitingForSession = false
    private var controller: SPUStandardUpdaterController!
    private var observers = Set<AnyCancellable>()
    private var pendingInstall: (() -> Void)?
    private var started = false
    private var observing = false

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticDownloads)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheck)
    }

    func observeApplication() {
        guard !observing else { return }
        observing = true
        let core = CoreModel.shared
        core.$isOnboarded.removeDuplicates().sink { [weak self] ready in
            if ready { self?.start() }
        }.store(in: &observers)
        core.$state.combineLatest(MeetingCapture.shared.$preparingID, MeetingCapture.shared.$stoppingID)
            .map { state, preparing, stopping in Self.activity(state, preparing: preparing, stopping: stopping) }
            .removeDuplicates()
            .sink { [weak self] activity in
                // @Published emits before storing its new value; resume after this main-loop turn.
                guard activity.permitsInstallation else { return }
                Task { @MainActor [weak self] in self?.resumeIfIdle() }
            }.store(in: &observers)
    }

    private func start() {
        guard !started else { return }
        do {
            try controller.updater.start()
            started = true
        } catch { self.error = error.localizedDescription }
    }

    private static func activity(_ state: AppState, preparing: Int64?, stopping: Int64?) -> UpdateActivity {
        UpdateActivity(busy: state.busy, recording: state.meetings.recording_id != nil,
                       processing: state.meetings.processing_id != nil,
                       analysis: state.analysis_id != nil || state.retranscribing_id != nil,
                       preparing: preparing != nil, stopping: stopping != nil)
    }

    var sessionActive: Bool {
        !Self.activity(CoreModel.shared.state, preparing: MeetingCapture.shared.preparingID,
                       stopping: MeetingCapture.shared.stoppingID).permitsInstallation
    }

    func check() {
        guard canCheck, !sessionActive else { return }
        error = nil
        controller.checkForUpdates(nil)
    }
    func setAutomaticChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        CoreModel.shared.refresh()
        if sessionActive {
            throw NSError(domain: "dev.local.diktation.updates", code: 1, userInfo: [NSLocalizedDescriptionKey:
                tr("La mise à jour attend la fin de votre enregistrement ou traitement.", "Updates wait until your recording or processing finishes.")])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        CoreModel.shared.refresh()
        guard sessionActive else { return false }
        pendingInstall = installHandler
        waitingForSession = true
        return true
    }

    private func resumeIfIdle() {
        guard pendingInstall != nil else { return }
        CoreModel.shared.refresh()
        guard !sessionActive else { return }
        let install = pendingInstall
        pendingInstall = nil; waitingForSession = false
        install?()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        pendingInstall = nil; waitingForSession = false
        let failure = error as NSError
        // Sparkle also ends a successful "already up to date" check here.
        // Deferring a scheduled check during recording is expected, too.
        if (failure.domain == SUSparkleErrorDomain && failure.code == Int(SUError.noUpdateError.rawValue)) ||
            (failure.domain == "dev.local.diktation.updates" && failure.code == 1) {
            self.error = nil
            return
        }
        self.error = error.localizedDescription
    }

    // No system profile, audio, notes or transcript are added to update requests.
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
}

struct UpdateMenuButton: View {
    @EnvironmentObject var core: CoreModel
    @ObservedObject private var updates = AppUpdates.shared
    @ObservedObject private var capture = MeetingCapture.shared
    var body: some View {
        Button(tr("Rechercher les mises à jour…", "Check for Updates…"), action: updates.check)
            .disabled(!updates.canCheck || updates.sessionActive)
    }
}

struct UpdateSettings: View {
    @EnvironmentObject var core: CoreModel
    @ObservedObject private var updates = AppUpdates.shared
    @ObservedObject private var capture = MeetingCapture.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Diktation \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").body(13, weight: .semibold)
                Spacer()
                Button(tr("Vérifier maintenant", "Check now"), action: updates.check)
                    .buttonStyle(QuietButtonStyle()).disabled(!updates.canCheck || updates.sessionActive)
            }.padding(.vertical, 8)
            ToggleRow(title: tr("Rechercher automatiquement", "Check automatically"),
                      hint: tr("Vérifie chaque jour si une nouvelle version est disponible.", "Checks daily for a new version."),
                      isOn: updates.automaticChecks, set: updates.setAutomaticChecks)
            ToggleRow(title: tr("Télécharger les mises à jour", "Download updates"),
                      hint: tr("Télécharge en arrière-plan et installe à la fermeture de l’app.", "Downloads in the background and installs when the app quits."),
                      isOn: updates.automaticDownloads, set: updates.setAutomaticDownloads)
                .disabled(!updates.automaticChecks)
            if updates.waitingForSession || updates.sessionActive {
                Text(tr("Votre session passe en premier. La mise à jour attendra.", "Your session comes first. The update will wait.")).body(11).foregroundStyle(Ink.secondary)
            } else if let date = updates.lastCheck {
                Text(tr("Dernière vérification : ", "Last checked: ") + date.formatted(date: .abbreviated, time: .shortened))
                    .body(11).foregroundStyle(Ink.secondary)
            }
            if let error = updates.error { Text(error).body(11).foregroundStyle(Ink.coral).textSelection(.enabled) }
        }.padding(.vertical, 4)
    }
}
