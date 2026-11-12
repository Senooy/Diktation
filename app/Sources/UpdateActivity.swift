/// Pure gate shared by automatic and manual updates, including microphone preparation.
struct UpdateActivity: Equatable {
    let busy: Bool
    let recording: Bool
    let processing: Bool
    let analysis: Bool
    let preparing: Bool
    let stopping: Bool
    var permitsInstallation: Bool { !(busy || recording || processing || analysis || preparing || stopping) }
}
