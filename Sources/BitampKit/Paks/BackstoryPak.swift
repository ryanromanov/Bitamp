import BitampPakProtocol
import CoreGraphics
import Foundation

/// The Backstory Pak: tells you about the song that's playing, from Apple's on-device model
/// (the default where the Mac has it, so nothing needs setting up), or from a service the
/// user picks with their own key. The on-device model also answers when the service has no
/// key, and when it can't be reached. A companion Pak: it has no music of its own, and its cartridge
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
        /// The service; with `wikipedia`, it writes from the song's Wikipedia article.
        public let make: @Sendable (_ wikipedia: Bool) -> BackstoryService?

        public init(isAvailable: @escaping @Sendable () -> Bool, make: @escaping @Sendable (_ wikipedia: Bool) -> BackstoryService?) {
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
    /// What notes the on-device model wrote from Wikipedia are saved under, apart from the
    /// ones it wrote from memory.
    static let onDeviceWikipediaName = "On-device/Wikipedia"

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
                                             options: services, defaultValue: defaultService)]
        for provider in providers {
            let prefix = provider.name.lowercased()
            settings.append(PakSettingDefinition(key: "\(prefix)-model", label: "\(provider.name) model", kind: .choice,
                                                 options: provider.models, defaultValue: provider.models.first))
            settings.append(PakSettingDefinition(key: "\(prefix)-key", label: "\(provider.name) API key", kind: .password))
        }
        // Its default depends on the service, so settingValues() fills it in.
        settings.append(PakSettingDefinition(key: "lookup", label: "Look up", kind: .choice,
                                             options: Lookup.allCases.map(\.rawValue)))
        // Sends the title, artist and album to Wikipedia, so it's off until asked for.
        if onDevice != nil {
            settings.append(PakSettingDefinition(key: "wikipedia", label: "On-device: look up Wikipedia", kind: .choice,
                                                 options: ["Off", "On"], defaultValue: "Off"))
        }
        // A song looked up early and then skipped still costs, so it's off until asked for.
        settings.append(PakSettingDefinition(key: "prefetch", label: "Next song early", kind: .choice,
                                             options: ["Off", "On"], defaultValue: "Off"))
        return settings
    }

    /// The services offered: the on-device model where there is one, then the cloud ones.
    var services: [String] {
        (onDevice == nil ? [] : [Self.onDeviceName]) + providers.map(\.name)
    }

    /// The on-device model where there is one, since it needs no key; otherwise the first
    /// cloud service.
    var defaultService: String {
        onDevice == nil ? providers[0].name : Self.onDeviceName
    }

    var settingsDescription: String? {
        onDevice == nil
            ? "Sends the song's title, artist and album, never the audio, to the service you pick, with your own key. Nothing goes to Bitamp."
            : "The on-device model is free and keeps everything on this Mac. With Wikipedia on, it writes from the song's Wikipedia article, which sends the title, artist and album to Wikipedia. For richer notes with sources, pick Claude or OpenAI and add your own key: only the title, artist and album are sent, never the audio, and nothing goes to Bitamp."
    }

    func settingValues() -> [String: String] {
        var values = store.values(for: manifest)
        if values["lookup"] == nil { values["lookup"] = defaultLookup(values).rawValue }
        return values
    }

    /// AUTO when the on-device model answers, since it's free; ASK for a cloud service,
    /// since lookups cost money and nothing should be looked up by itself until the user says so.
    private func defaultLookup(_ values: [String: String]) -> Lookup {
        guard onDevice != nil else { return .whenAsked }
        let service = values["service"]
        if service == Self.onDeviceName { return .everyTrack }
        let provider = providers.first { $0.name == service } ?? providers[0]
        let key = values["\(provider.name.lowercased())-key"] ?? ""
        return key.isEmpty ? .everyTrack : .whenAsked
    }

    func configure(_ values: [String: String]) async throws {
        save(values)
    }

    /// Changes some settings, keeping the rest.
    func save(_ changes: [String: String]) {
        var values = settingValues().merging(changes) { $1 }
        // The lookup is kept only once the user picks one. Until then it follows the service,
        // so moving from the free on-device model to a paid one goes back to ASK.
        if store.savedValue("lookup", for: id) == nil, values["lookup"] == settingValues()["lookup"] {
            values["lookup"] = nil
        }
        store.save(values, for: manifest)
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
        get { settingValues()["lookup"].flatMap(Lookup.init) ?? defaultLookup(settingValues()) }
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

    /// Whether the on-device model looks the song up on Wikipedia and writes from the article.
    var usesWikipedia: Bool {
        get { onDevice != nil && settingValues()["wikipedia"] == "On" }
        set { save(["wikipedia": newValue ? "On" : "Off"]) }
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
        let wikipedia = usesWikipedia
        guard let onDevice, onDevice.isAvailable(), let service = onDevice.make(wikipedia) else { return nil }
        return Choice(service: service, identity: wikipedia ? Self.onDeviceWikipediaName : Self.onDeviceName, onDevice: true)
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
