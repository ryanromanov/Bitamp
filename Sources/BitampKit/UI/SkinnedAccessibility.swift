import AppKit

/// A control as VoiceOver sees it, in a skinned window that draws its own controls. The
/// window lists these (`SkinnedView.accessibleControls`) from the same areas its clicks use,
/// and `SkinnedView` turns them into accessibility elements.
struct AccessibleControl {
    enum Kind {
        case button
        /// On or off.
        case checkBox(Bool)
        /// A value from 0 to 1, said as `description`, moved by `increment` and `decrement`.
        case slider(Double, description: String)
        /// Words to read, such as the song that's playing.
        case text
        /// A link, such as a source to open in the browser.
        case link
    }

    /// Stays the same while the control does, so VoiceOver keeps its place.
    let id: AnyHashable
    var kind: Kind
    var label: String
    /// Where it's drawn, in skin pixels.
    var rect: CGRect
    var help: String?
    var isEnabled = true
    var press: (() -> Void)?
    var increment: (() -> Void)?
    var decrement: (() -> Void)?
    /// Sets a slider to a value from 0 to 1, as VoiceOver may.
    var setValue: ((Double) -> Void)?

    /// Which element class shows it; a control whose kind changes gets a new element.
    var elementClass: SkinnedAccessibilityElement.Type {
        switch kind {
        case .button: SkinnedButtonElement.self
        case .checkBox: SkinnedCheckBoxElement.self
        case .slider: SkinnedSliderElement.self
        case .text: SkinnedTextElement.self
        case .link: SkinnedLinkElement.self
        }
    }
}

/// One of a skinned window's controls, for VoiceOver. It asks its window for what's current
/// each time, so labels and values stay live and its outline follows the window.
///
/// There's a subclass for each kind. The slider's adopts `NSAccessibilitySlider`, which is
/// how AppKit learns VoiceOver can step it.
@MainActor
class SkinnedAccessibilityElement: NSAccessibilityElement {
    weak var owner: SkinnedView?
    let id: AnyHashable

    required init(owner: SkinnedView, id: AnyHashable) {
        self.owner = owner
        self.id = id
        super.init()
        setAccessibilityParent(owner)
    }

    var control: AccessibleControl? { owner?.accessibleControl(id) }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? {
        switch control?.kind {
        case .button?: .button
        case .checkBox?: .checkBox
        case .slider?: .slider
        case .link?: .link
        case .text?, nil: .staticText
        }
    }

    override func accessibilityLabel() -> String? { control?.label }
    override func accessibilityHelp() -> String? { control?.help }
    override func isAccessibilityEnabled() -> Bool { control?.isEnabled ?? false }

    override func accessibilityValue() -> Any? {
        switch control?.kind {
        case .checkBox(let on)?: on ? 1 : 0
        case .slider(let value, _)?: value
        default: nil
        }
    }

    override func accessibilityValueDescription() -> String? {
        if case .slider(_, let description)? = control?.kind { return description }
        return nil
    }

    override func accessibilityMinValue() -> Any? { 0.0 }
    override func accessibilityMaxValue() -> Any? { 1.0 }

    override func accessibilityFrameInParentSpace() -> NSRect {
        guard let owner, let control else { return .zero }
        return owner.viewRect(forPixels: control.rect)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let control, control.isEnabled, let press = control.press else { return false }
        press()
        return true
    }

    override func accessibilityPerformIncrement() -> Bool {
        step(control?.increment)
    }

    override func accessibilityPerformDecrement() -> Bool {
        step(control?.decrement)
    }

    override func setAccessibilityValue(_ value: Any?) {
        guard let control, control.isEnabled, let setValue = control.setValue,
              let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init) else { return }
        setValue(min(max(number, 0), 1))
        changed()
    }

    fileprivate func step(_ action: (() -> Void)?) -> Bool {
        guard let control, control.isEnabled, let action else { return false }
        action()
        changed()
        return true
    }

    private func changed() {
        NSAccessibility.post(element: self, notification: .valueChanged)
        owner?.needsDisplay = true
    }
}

final class SkinnedButtonElement: SkinnedAccessibilityElement {}
final class SkinnedCheckBoxElement: SkinnedAccessibilityElement {}
final class SkinnedTextElement: SkinnedAccessibilityElement {
    override func accessibilityValue() -> Any? { control?.label }
}
final class SkinnedLinkElement: SkinnedAccessibilityElement {}

/// Adopting `NSAccessibilitySlider` is what makes VoiceOver offer its steps.
final class SkinnedSliderElement: SkinnedAccessibilityElement, @preconcurrency NSAccessibilitySlider {
    override func accessibilityIdentifier() -> String { "\(id)" }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        selector == #selector(setAccessibilityValue(_:)) ? control?.setValue != nil : super.isAccessibilitySelectorAllowed(selector)
    }
}

/// Volume and balance as VoiceOver says and steps them; the main window and the
/// equalizer's shade strip share these.
extension PlaybackController {
    var volumeDescription: String { "\(Int((volume * 100).rounded()))%" }

    var balanceDescription: String {
        balance == 0 ? "Center" : "\(Int((abs(balance) * 100).rounded()))% \(balance < 0 ? "left" : "right")"
    }

    /// 5% a step.
    func stepVolume(_ direction: Double) {
        volume = min(max(volume + direction * 0.05, 0), 1)
    }

    /// Ten steps a side, landing on center.
    func stepBalance(_ direction: Double) {
        balance = min(max(((balance + direction * 0.1) * 10).rounded() / 10, -1), 1)
    }
}

extension EqualizerLabels {
    /// "60 Hz", "1 kHz": the band names as VoiceOver says them.
    static let spokenNames = names.map { $0.replacingOccurrences(of: "KHZ", with: "kHz").replacingOccurrences(of: "HZ", with: "Hz") }

    static func spokenDecibels(_ value: Float) -> String {
        decibels(value).replacingOccurrences(of: "DB", with: "dB")
    }
}
