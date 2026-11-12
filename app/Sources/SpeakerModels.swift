import SwiftUI

struct SpeakerModelsView: View {
    @EnvironmentObject var core: CoreModel
    @ObservedObject private var downloader = ModelDownloader.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(core.state.speaker_models) { model in
                HStack {
                    Text(model.label).body(13)
                    Spacer()
                    if model.installed {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if downloader.model?.file == model.file && downloader.isActive {
                        ProgressView(value: downloader.progress).frame(width: 100)
                        if downloader.phase == .downloading {
                            Button(tr("Annuler", "Cancel")) { downloader.cancel() }
                        }
                    } else {
                        Button(tr("Télécharger", "Download") + " · " + ModelDownloader.format(bytes: model.bytes)) {
                            downloader.start(model, into: core.state.install_dir)
                        }.disabled(downloader.isActive)
                    }
                }
            }
            if downloader.model?.engine == "diarization", case .failed(let message) = downloader.phase {
                Text(message).body(12).foregroundStyle(.red)
                Button(tr("Réessayer", "Retry")) { downloader.retry() }
            }
        }.padding(.vertical, 10)
    }
}
