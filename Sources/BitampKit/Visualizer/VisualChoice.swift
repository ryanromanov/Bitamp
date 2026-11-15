/// What the user picked in the visualizer: one of the visuals, or, under Presets, Drift (which
/// fades through every preset in turn) or one preset by name. Saved as a string: a `FullVisual`
/// raw value, `presets` for Drift, or `preset:Name`.
struct VisualChoice: Equatable {
    var visual: FullVisual
    /// The preset's name, for `.presets`; nil is Drift.
    var preset: String?

    init(visual: FullVisual, preset: String? = nil) {
        self.visual = visual
        self.preset = preset
    }

    init(raw: String) {
        if raw.hasPrefix("preset:") {
            self.init(visual: .presets, preset: String(raw.dropFirst(7)))
        } else {
            self.init(visual: FullVisual(rawValue: raw) ?? .barsAndWaves)
        }
    }

    var raw: String { preset.map { "preset:\($0)" } ?? visual.rawValue }
    var title: String { preset ?? visual.title }

    /// Every choice in menu and arrow-key order: the visuals, then Drift, then each preset.
    static func all(presetNames: [String]) -> [VisualChoice] {
        FullVisual.allCases.filter { $0 != .presets }.map { VisualChoice(visual: $0) }
            + [VisualChoice(visual: .presets)] + presetNames.map { VisualChoice(visual: .presets, preset: $0) }
    }
}
