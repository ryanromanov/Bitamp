import Foundation

/// A MilkDrop preset (`.milk`): its settings, the code that moves the picture, and the
/// custom waves and shapes drawn on top.
struct MilkPreset {
    /// Every `key=value` line with a number for its value, keys in lower case.
    var numbers: [String: Double] = [:]
    var perFrameInit = ""
    var perFrame = ""
    var perPixel = ""
    var waves: [Wave] = (0..<4).map { Wave(index: $0) }
    var shapes: [Shape] = (0..<4).map { Shape(index: $0) }
    /// HLSL for the warp and composite passes, if the preset has them.
    var warpShader = ""
    var compShader = ""

    struct Wave {
        let index: Int
        var numbers: [String: Double] = [:]
        var initCode = ""
        var perFrame = ""
        var perPoint = ""
        var enabled: Bool { (numbers["enabled"] ?? 0) != 0 }
    }

    struct Shape {
        let index: Int
        var numbers: [String: Double] = [:]
        var initCode = ""
        var perFrame = ""
        var enabled: Bool { (numbers["enabled"] ?? 0) != 0 }
    }

    func number(_ key: String, _ fallback: Double = 0) -> Double { numbers[key.lowercased()] ?? fallback }

    init(text: String) {
        // Numbered code lines (`per_frame_1`, `per_frame_2`, ...) are joined in order.
        var code: [String: [(Int, String)]] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let equals = raw.firstIndex(of: "=") else { continue }
            let key = raw[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(raw[raw.index(after: equals)...])
            if let (group, line) = Self.codeLine(key) {
                code[group, default: []].append((line, value))
            } else if let number = Double(value.trimmingCharacters(in: .whitespaces)) {
                if let (kind, index, name) = Self.indexed(key) {
                    if kind == "wavecode", index < 4 { waves[index].numbers[name] = number }
                    if kind == "shapecode", index < 4 { shapes[index].numbers[name] = number }
                } else {
                    numbers[key] = number
                }
            }
        }
        func joined(_ group: String) -> String {
            (code[group] ?? []).sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
        }
        perFrameInit = joined("per_frame_init")
        perFrame = joined("per_frame")
        perPixel = joined("per_pixel")
        warpShader = joined("warp")
        compShader = joined("comp")
        for i in 0..<4 {
            waves[i].initCode = joined("wave_\(i)_init")
            waves[i].perFrame = joined("wave_\(i)_per_frame")
            waves[i].perPoint = joined("wave_\(i)_per_point")
            shapes[i].initCode = joined("shape_\(i)_init")
            shapes[i].perFrame = joined("shape_\(i)_per_frame")
        }
    }

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Presets are plain text of no declared encoding; Latin-1 never fails.
        self.init(text: String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
    }

    /// `per_frame_12` -> ("per_frame", 12); `wave_2_per_point3` -> ("wave_2_per_point", 3).
    private static func codeLine(_ key: String) -> (String, Int)? {
        let digits = key.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, let line = Int(String(digits.reversed())) else { return nil }
        var group = String(key.dropLast(digits.count))
        if group.hasSuffix("_") { group.removeLast() }
        // `per_frame_init_1` and `wave_0_init1` both end in a number; `shapecode_0_...` doesn't.
        let known = ["per_frame_init", "per_frame", "per_pixel", "warp", "comp"]
        if known.contains(group) { return (group, line) }
        let parts = group.split(separator: "_")
        if parts.count >= 3, parts[0] == "wave" || parts[0] == "shape", Int(parts[1]) != nil,
           ["init", "per_frame", "per_point"].contains(parts.dropFirst(2).joined(separator: "_")) {
            return (group, line)
        }
        return nil
    }

    /// `wavecode_1_scaling` -> ("wavecode", 1, "scaling").
    private static func indexed(_ key: String) -> (String, Int, String)? {
        let parts = key.split(separator: "_", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "wavecode" || parts[0] == "shapecode", let index = Int(parts[1]) else { return nil }
        return (parts[0], index, parts[2])
    }
}
