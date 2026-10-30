import BitampPakProtocol
import CoreGraphics
import Foundation

/// The Backstory Pak: tells you about the song that's playing, from a service the user
/// picks with their own key, or from Apple's on-device model: when chosen, when there's no
/// key, and when the service can't be reached. A companion Pak: it has no music of its own, and its cartridge
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

    /// Apple's on-device model, where this Mac has it.
    public struct OnDevice: Sendable {
        /// Whether it can answer now; it may still be downloading.
        public let isAvailable: @Sendable () -> Bool
        public let make: @Sendable () -> BackstoryService?

        public init(isAvailable: @escaping @Sendable () -> Bool, make: @escaping @Sendable () -> BackstoryService?) {
            self.isAvailable = isAvailable
            self.make = make
        }
    }

    /// The service a lookup goes to, and the name its notes are saved under.
    struct Choice {
        let service: BackstoryService
        let identity: String
        let onDevice: Bool
    }

    static let onDeviceName = "On-device"

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
    let onDevice: OnDevice?
    private let store: PakSettingsStore
    /// Called when a setting changes, from the window or the form.
    var onChange: (() -> Void)?

    public convenience init(providers: [Provider], onDevice: OnDevice? = nil) {
        self.init(providers: providers, onDevice: onDevice, store: PakSettingsStore())
    }

    init(providers: [Provider], onDevice: OnDevice? = nil, store: PakSettingsStore) {
        precondition(!providers.isEmpty, "Backstory needs a service")
        self.providers = providers
        self.onDevice = onDevice
        self.store = store
    }

    // MARK: - Settings

    private var manifest: PakManifest {
        PakManifest(id: id, name: name, version: "1", executable: "", settings: settingDefinitions)
    }

    var settingDefinitions: [PakSettingDefinition] {
        var settings = [PakSettingDefinition(key: "service", label: "Service", kind: .choice,
                                             options: services, defaultValue: providers[0].name)]
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

    /// The services offered: the cloud ones, then the on-device model where there is one.
    var services: [String] {
        providers.map(\.name) + (onDevice == nil ? [] : [Self.onDeviceName])
    }

    var settingsDescription: String? {
        "Sends the song's title, artist and album, never the audio, to the service you pick, with your own key. Nothing goes to Bitamp. The on-device model keeps everything on this Mac."
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

    /// Whether the on-device model is the service chosen.
    var choosesOnDevice: Bool {
        onDevice != nil && settingValues()["service"] == Self.onDeviceName
    }

    /// Where a lookup goes now: the service chosen if it has a key, or else the on-device
    /// model. Nil when neither can answer, and the setup is needed.
    func choice() -> Choice? {
        if !choosesOnDevice {
            let provider = self.provider
            if let key = key(for: provider) {
                return Choice(service: provider.make(model(of: provider), key), identity: identity, onDevice: false)
            }
        }
        return onDeviceChoice()
    }

    /// The on-device model, if this Mac can run it now.
    func onDeviceChoice() -> Choice? {
        guard let onDevice, onDevice.isAvailable(), let service = onDevice.make() else { return nil }
        return Choice(service: service, identity: Self.onDeviceName, onDevice: true)
    }

    // MARK: - Pak

    public var account: PakAccount {
        guard let choice = choice() else { return .disconnected }
        let provider = self.provider
        return .connected(name: choice.onDevice ? "On-device model" : "\(provider.name) \(model(of: provider))")
    }

    public func connect() async throws {}
    public func disconnect() {}
    public func search(_ term: String) async throws -> [PakTrack] { [] }
    public func metadata(for url: URL) async -> PakTrack? { nil }
    public func playback(for url: URL) throws -> PakPlayback { throw CocoaError(.featureUnsupported) }
}
