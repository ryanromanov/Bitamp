import BitampPakSDK
import Foundation

/// Bitamp's demo Expansion Pak: a few public-domain tunes it plays as chiptunes, made on
/// the spot. It shows everything a Pak does (settings, search, track info, audio) with
/// no server or account. Package it with `scripts/make-pak.sh`; see docs/PAK-SDK.md.
final class DemoPak: PakProvider {
    private var waveform = Synth.Waveform.square
    private var cache = FileManager.default.temporaryDirectory

    func configure(_ context: PakContext) async throws -> PakAccountState {
        waveform = context.settings["waveform"].flatMap(Synth.Waveform.init(rawValue:)) ?? .square
        cache = context.cacheDirectory
        return .connected
    }

    /// Every tune for an empty search; otherwise those whose title or composer match.
    func search(_ term: String) async throws -> [PakTrackInfo] {
        let term = term.trimmingCharacters(in: .whitespaces)
        return Tune.all
            .filter { term.isEmpty || $0.title.localizedCaseInsensitiveContains(term)
                || $0.composer.localizedCaseInsensitiveContains(term) }
            .map(info)
    }

    func track(id: String) async throws -> PakTrackInfo? {
        Tune.all.first { $0.id == id }.map(info)
    }

    func resolve(id: String) async throws -> PakSource {
        guard let tune = Tune.all.first(where: { $0.id == id }) else { throw PakFailure("No tune called \(id)") }
        let file = cache.appendingPathComponent("\(tune.id)-\(waveform.rawValue.lowercased()).wav")
        if !FileManager.default.fileExists(atPath: file.path) {
            try Synth.render(tune, waveform: waveform, to: file)
        }
        return .file(file)
    }

    private func info(_ tune: Tune) -> PakTrackInfo {
        PakTrackInfo(id: tune.id, title: tune.title, artist: tune.composer, album: "Bitamp Demo Pak", duration: tune.duration)
    }
}

PakRunner.run(DemoPak())
