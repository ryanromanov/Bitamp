import BitampPakProtocol
import CoreGraphics
import Foundation

/// The Backstory Pak: tells you about the song that's playing, from a service the user
/// picks with their own key. A companion Pak: it has no music of its own, and its cartridge
/// opens the Backstory window instead of the Media Library.
///
/// Settings live where a third-party Pak's do (UserDefaults, the key in the Keychain), so
/// the cartridge's Settings… form and the window's setup change the same values.
@MainActor
public final class BackstoryPak: Pak, ConfigurablePak {
    /// A service the notes can come from, such as Claude.
    public struct Provider: Sendable {
        public let name: String
        /// The models offered, by the name shown; the first is the default.
        public let models: [String]
        /// What each model costs, roughly, for the setup: "about 4¢ a song".
        public let costs: [String: String]
        public let make: @Sendable (_ model: String, _ key: String) -> BackstoryService

        public init(name: String, models: [String], costs: [String: String] = [:],
                    make: @escaping @Sendable (_ model: String, _ key: String) -> BackstoryService) {
            self.name = name
            self.models = models
            self.costs = costs
            self.make = make
        }
    }

    /// When notes are looked up.
    enum Lookup: String, CaseIterable {
        case everyTrack = "Every track", whenAsked = "When I ask", off = "Off"
    }

    static let pakID = "backstory"
    public let id = BackstoryPak.pakID
    public let name = "Backstory"
    public let schemes: Set<String> = []
    public let isAvailable = true
    public var isMusicSource: Bool { false }

    let providers: [Provider]
    private let store: PakSettingsStore
    /// Called when a setting changes, from the window or the form.
    var onChange: (() -> Void)?

    public convenience init(providers: [Provider]) {
        self.init(providers: providers, store: PakSettingsStore())
    }

    init(providers: [Provider], store: PakSettingsStore) {
        precondition(!providers.isEmpty, "Backstory needs a service")
        self.providers = providers
        self.store = store
    }

    // MARK: - Settings

    private var manifest: PakManifest {
        PakManifest(id: id, name: name, version: "1", executable: "", settings: settingDefinitions)
    }

    var settingDefinitions: [PakSettingDefinition] {
        var settings = [PakSettingDefinition(key: "service", label: "Service", kind: .choice,
                                             options: providers.map(\.name), defaultValue: providers[0].name)]
        for provider in providers {
            let prefix = provider.name.lowercased()
            settings.append(PakSettingDefinition(key: "\(prefix)-model", label: "\(provider.name) model", kind: .choice,
                                                 options: provider.models, defaultValue: provider.models.first))
            settings.append(PakSettingDefinition(key: "\(prefix)-key", label: "\(provider.name) API key", kind: .password))
        }
        // Lookups cost money, so nothing is looked up by itself until the user says so.
        settings.append(PakSettingDefinition(key: "lookup", label: "Look up", kind: .choice,
                                             options: Lookup.allCases.map(\.rawValue), defaultValue: Lookup.whenAsked.rawValue))
        // A song looked up early and then skipped still costs, so it's off until asked for.
        settings.append(PakSettingDefinition(key: "prefetch", label: "Next song early", kind: .choice,
                                             options: ["Off", "On"], defaultValue: "Off"))
        return settings
    }

    var settingsDescription: String? {
        "Sends the song's title, artist and album, never the audio, to the service you pick, with your own key. Nothing goes to Bitamp."
    }

    func settingValues() -> [String: String] {
        store.values(for: manifest)
    }

    func configure(_ values: [String: String]) async throws {
        save(values)
    }

    /// Changes some settings, keeping the rest.
    func save(_ changes: [String: String]) {
        store.save(settingValues().merging(changes) { $1 }, for: manifest)
        onChange?()
    }

    var provider: Provider {
        let name = settingValues()["service"]
        return providers.first { $0.name == name } ?? providers[0]
    }

    func model(of provider: Provider) -> String {
        let model = settingValues()["\(provider.name.lowercased())-model"]
        return provider.models.contains { $0 == model } ? model! : provider.models[0]
    }

    func key(for provider: Provider) -> String? {
        settingValues()["\(provider.name.lowercased())-key"].flatMap { $0.isEmpty ? nil : $0 }
    }

    var lookup: Lookup {
        get { settingValues()["lookup"].flatMap(Lookup.init) ?? .whenAsked }
        set { save(["lookup": newValue.rawValue]) }
    }

    /// Which service and model, such as "Claude/Sonnet 5.5". Notes are saved under it, so
    /// changing the model doesn't show another model's notes.
    var identity: String {
        let provider = self.provider
        return "\(provider.name)/\(model(of: provider))"
    }

    /// With "Every track", look the next song up shortly before this one ends, so its notes
    /// are there when it starts.
    var prefetch: Bool {
        get { settingValues()["prefetch"] == "On" }
        set { save(["prefetch": newValue ? "On" : "Off"]) }
    }

    /// The service to ask, or nil until there's a key for it.
    func service() -> BackstoryService? {
        let provider = self.provider
        guard let key = key(for: provider) else { return nil }
        return provider.make(model(of: provider), key)
    }

    // MARK: - Pak

    public var account: PakAccount {
        let provider = self.provider
        return key(for: provider) == nil ? .disconnected : .connected(name: "\(provider.name) \(model(of: provider))")
    }

    public func connect() async throws {}
    public func disconnect() {}
    public func search(_ term: String) async throws -> [PakTrack] { [] }
    public func metadata(for url: URL) async -> PakTrack? { nil }
    public func playback(for url: URL) throws -> PakPlayback { throw CocoaError(.featureUnsupported) }
}
