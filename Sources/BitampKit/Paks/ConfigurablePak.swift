import BitampPakProtocol

/// A Pak with settings the user fills in: a third-party Pak's, from its manifest, or a
/// built-in one's. The settings form (right-click a cartridge ▸ Settings…) works for both.
@MainActor
protocol ConfigurablePak: Pak {
    var settingDefinitions: [PakSettingDefinition] { get }
    /// A line about the Pak for the form, if it has one.
    var settingsDescription: String? { get }
    func settingValues() -> [String: String]
    /// Saves new settings and puts them to use.
    func configure(_ values: [String: String]) async throws
}

extension ConfigurablePak {
    var hasSettings: Bool { !settingDefinitions.isEmpty }
}

extension ExternalPak: ConfigurablePak {
    var settingDefinitions: [PakSettingDefinition] { manifest.settings ?? [] }
    var settingsDescription: String? { manifest.description }
}
