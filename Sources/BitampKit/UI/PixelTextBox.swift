import AppKit

/// A one-line text box drawn in the playlist's pixel font, for a skinned window.
///
/// An `NSTextField` does the editing, so typing, selection, the clipboard, undo, accents
/// and the emoji picker all work as anywhere on the Mac. Its text and caret are clear, and
/// it sits over the box so input methods put their windows nearby; the canvas draws the
/// text, selection, marked text and caret from the field editor's state. Clicks go to the
/// view, which passes them to `mouseDown`.
@MainActor
final class PixelTextBox: NSObject, NSTextFieldDelegate {
    /// The box, in the view's skin pixels.
    var rect: CGRect {
        didSet { place() }
    }
    var placeholder: String
    /// Called with the text when Return is pressed.
    var onSubmit: ((String) -> Void)?
    /// Called when Escape is pressed in an empty box.
    var onCancel: (() -> Void)?

    private let field = ClearTextField()
    private weak var view: SkinnedView?
    /// How far the text is scrolled left to keep the caret in view, in pixels.
    private var scroll = 0
    /// Where a drag started, as a UTF-16 offset.
    private var anchor: Int?

    init(in view: SkinnedView, rect: CGRect, placeholder: String) {
        self.view = view
        self.rect = rect
        self.placeholder = placeholder
        super.init()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .clear
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        view.addSubview(field)
        place()
    }

    var text: String {
        get { editor?.string ?? field.stringValue }
        set {
            field.stringValue = newValue
            editor?.string = newValue
        }
    }

    /// The field editor, while this box is being edited.
    private var editor: NSTextView? {
        guard let editor = view?.window?.firstResponder as? NSTextView, editor.delegate === field else { return nil }
        return editor
    }

    var isEditing: Bool { editor != nil }

    func focus() {
        view?.window?.makeFirstResponder(field)
    }

    /// Keeps the field over the box, at the view's scale. Call after the view's size changes.
    func place() {
        guard let view else { return }
        let font = NSFont.systemFont(ofSize: 8 * view.scale)
        field.font = font
        var frame = view.viewRect(forPixels: rect.insetBy(dx: 3, dy: 0))
        let height = ceil(font.ascender - font.descender + font.leading) + 2
        frame.origin.y += ((frame.height - height) / 2).rounded()
        frame.size.height = height
        field.frame = frame
    }

    // MARK: - Drawing

    func draw(_ c: Canvas, skin: Skin, frameCount: Int) {
        let colors = skin.playlistColors
        let dim = mix(colors.normal, colors.normalBackground, 0.45)
        let editor = self.editor
        c.fill(rect, mix(colors.normalBackground, colors.normal, 0.12))
        c.bevel(Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height),
                light: mix(colors.normalBackground, rgb(0), 0.5),
                dark: mix(colors.normalBackground, colors.normal, editor != nil ? 0.9 : 0.4))

        let text = self.text
        let inner = rect.insetBy(dx: 3, dy: 1)
        let selection = editor?.selectedRange() ?? NSRange(location: (text as NSString).length, length: 0)
        let caret = x(text, selection.location + selection.length)
        if editor == nil {
            scroll = 0
        } else if caret - scroll > Int(inner.width) - 2 {
            scroll = caret - Int(inner.width) + 2
        } else if caret < scroll {
            scroll = caret
        }

        c.context.saveGState()
        c.context.clip(to: inner)
        let left = Int(inner.minX) - scroll, top = Int(inner.minY)
        if text.isEmpty && editor == nil {
            ListFont.draw(placeholder, in: c, x: left, y: top, color: dim)
        }
        if let editor {
            if selection.length > 0 {
                let from = x(text, selection.location), to = x(text, selection.location + selection.length)
                c.fill(left + from, top, to - from, ListFont.lineHeight, colors.selectedBackground)
            }
            if editor.hasMarkedText() {
                let marked = editor.markedRange()
                let from = x(text, marked.location), to = x(text, marked.location + marked.length)
                c.fill(left + from, top + ListFont.lineHeight - 1, max(1, to - from - 1), 1, colors.current)
            }
        }
        ListFont.draw(text, in: c, x: left, y: top, color: colors.normal)
        if editor != nil, selection.length == 0, (frameCount / 15) % 2 == 0 {
            c.fill(left + caret, top + 1, 1, ListFont.lineHeight - 2, colors.current)
        }
        c.context.restoreGState()
    }

    /// Pixels from the start of `text` to the boundary before UTF-16 offset `offset`.
    private func x(_ text: String, _ offset: Int) -> Int {
        let prefix = (text as NSString).substring(to: min(offset, (text as NSString).length))
        return prefix.isEmpty ? 0 : ListFont.width(of: prefix) + ListFont.letterSpacing
    }

    /// The character boundary nearest `px` pixels into the text, as a UTF-16 offset.
    private func offset(_ text: String, at px: Int) -> Int {
        var best = 0, bestDistance = Int.max
        var index = text.startIndex
        while true {
            let offset = text.utf16.distance(from: text.utf16.startIndex, to: index)
            let distance = abs(x(text, offset) - px)
            if distance < bestDistance { (best, bestDistance) = (offset, distance) }
            guard index < text.endIndex else { break }
            index = text.index(after: index)
        }
        return best
    }

    // MARK: - Mouse

    /// Takes a click in the box: focuses it and places the caret, selects a word's worth on
    /// a double click, or extends with Shift. False if the click wasn't in the box.
    func mouseDown(at point: CGPoint, event: NSEvent) -> Bool {
        guard rect.contains(point) else { return false }
        if editor == nil { focus() }
        guard let editor else { return true }
        let at = offset(editor.string, at: Int(point.x - rect.minX - 3) + scroll)
        if event.clickCount >= 2 {
            editor.selectAll(nil)
            anchor = nil
        } else if event.modifierFlags.contains(.shift) {
            let start = editor.selectedRange().location
            editor.setSelectedRange(NSRange(location: min(start, at), length: abs(at - start)))
            anchor = start
        } else {
            editor.setSelectedRange(NSRange(location: at, length: 0))
            anchor = at
        }
        return true
    }

    func mouseDragged(to point: CGPoint) {
        guard let anchor, let editor else { return }
        let at = offset(editor.string, at: Int(point.x - rect.minX - 3) + scroll)
        editor.setSelectedRange(NSRange(location: min(anchor, at), length: abs(at - anchor)))
    }

    func mouseUp() {
        anchor = nil
    }

    // MARK: - Return and Escape

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(textView.string)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if textView.string.isEmpty {
                view?.window?.makeFirstResponder(view)
                onCancel?()
            } else {
                text = ""
            }
            return true
        default:
            return false
        }
    }
}

/// A text field that lets clicks through to the view behind it and makes the window's
/// shared field editor draw nothing while it edits.
private final class ClearTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = .clear
            editor.selectedTextAttributes = [.foregroundColor: NSColor.clear, .backgroundColor: NSColor.clear]
            editor.markedTextAttributes = [.foregroundColor: NSColor.clear]
        }
        return true
    }
}
