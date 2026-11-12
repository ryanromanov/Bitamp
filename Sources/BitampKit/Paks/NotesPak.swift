import Foundation

/// When notes are looked up.
enum NotesLookup: String, CaseIterable {
    case everyTrack = "Every track", whenAsked = "When I ask", off = "Off"
}

/// The service a lookup goes to, and the name its notes are saved under.
struct NotesChoice {
    let service: BackstoryService
    let identity: String
    /// Apple's on-device model, which the window marks.
    let onDevice: Bool
}

/// A companion Pak whose window shows notes about the song that's playing: Backstory, or a
/// third-party Pak whose manifest lists the `notes` capability. `BackstorySession` follows
/// the song and asks it, and `BackstoryView` shows what comes back.
@MainActor
protocol NotesPak: Pak {
    var lookup: NotesLookup { get set }
    /// With "Every track", look the next song up shortly before this one ends.
    var prefetch: Bool { get set }
    /// What notes are saved under when there's no service to ask.
    var identity: String { get }
    /// Where a lookup goes now. Nil when nothing can answer, and the Pak needs setting up.
    func choice() -> NotesChoice?
    /// What answers when the chosen service can't be reached, if anything.
    func onDeviceChoice() -> NotesChoice?
}
