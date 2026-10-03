import CoreGraphics

enum PlayStatus: Hashable {
    case playing, paused, stopped
}

/// One sprite on the main window. Comments name the matching `.wsz` sprite.
enum SkinElement: Hashable {
    case mainBackground                                  // MAIN_WINDOW_BACKGROUND
    case titleBar(active: Bool)                          // MAIN_TITLE_BAR(_SELECTED)
    case titleButton(TitleButton, pressed: Bool)         // MAIN_CLOSE_BUTTON, MAIN_MINIMIZE_BUTTON, …
    case transport(TransportButton, pressed: Bool)       // MAIN_PLAY_BUTTON(_ACTIVE), …
    case playStatus(PlayStatus)                          // MAIN_PLAYING_INDICATOR, …
    case mono(active: Bool)                              // MAIN_MONO(_SELECTED)
    case stereo(active: Bool)                            // MAIN_STEREO(_SELECTED)
    case volumeBackground(level: Int)                    // one of MAIN_VOLUME_BACKGROUND's 28 frames
    case volumeThumb(pressed: Bool)                      // MAIN_VOLUME_THUMB(_SELECTED)
    case balanceBackground(level: Int)                   // one of MAIN_BALANCE_BACKGROUND's 28 frames
    case balanceThumb(pressed: Bool)                     // MAIN_BALANCE_THUMB(_ACTIVE)
    case positionBackground                              // MAIN_POSITION_SLIDER_BACKGROUND
    case positionThumb(pressed: Bool)                    // MAIN_POSITION_SLIDER_THUMB(_SELECTED)
    case toggle(ToggleButton, on: Bool, pressed: Bool)   // MAIN_SHUFFLE_BUTTON, MAIN_EQ_BUTTON, …
    case about(pressed: Bool)                            // MAIN_ABOUT_BUTTON
    case digit(Int)                                      // DIGIT_0…9; 10 is a blank digit
    case minus                                           // MINUS_SIGN

    // Equalizer window
    case eqBackground                                    // EQ_WINDOW_BACKGROUND
    case eqTitleBar(active: Bool)                        // EQ_TITLE_BAR(_SELECTED)
    case eqCloseButton(pressed: Bool)                    // EQ_CLOSE_BUTTON(_ACTIVE)
    case eqButton(EQButton, on: Bool, pressed: Bool)     // EQ_ON_BUTTON, EQ_AUTO_BUTTON, EQ_PRESETS_BUTTON
    case eqSliderBackground(level: Int)                  // one of EQ_SLIDER_BACKGROUND's 28 frames; 0 is -12 dB
    case eqSliderThumb(pressed: Bool)                    // EQ_SLIDER_THUMB(_SELECTED)
    case eqGraphBackground                               // EQ_GRAPH_BACKGROUND
    case eqPreampLine                                    // EQ_PREAMP_LINE

    // Playlist window, drawn from tiles so it can grow
    case playlistTopLeft(active: Bool)                   // PLAYLIST_TOP_LEFT_CORNER(_SELECTED)
    case playlistTitle(active: Bool)                     // PLAYLIST_TITLE_BAR(_SELECTED)
    case playlistTopTile(active: Bool)                   // PLAYLIST_TOP_TILE(_SELECTED)
    case playlistTopRight(active: Bool)                  // PLAYLIST_TOP_RIGHT_CORNER(_SELECTED)
    case playlistLeftTile                                // PLAYLIST_LEFT_TILE
    case playlistRightTile                               // PLAYLIST_RIGHT_TILE
    case playlistBottomLeft                              // PLAYLIST_BOTTOM_LEFT_CORNER
    case playlistBottomRight                             // PLAYLIST_BOTTOM_RIGHT_CORNER
    case playlistBottomTile                              // PLAYLIST_BOTTOM_TILE
    case playlistScrollThumb(pressed: Bool)              // PLAYLIST_SCROLL_HANDLE(_SELECTED)
    case playlistCloseButton(pressed: Bool)              // PLAYLIST_CLOSE_SELECTED

    static let sliderLevels = 28
    static let blankDigit = 10
}

/// Supplies every sprite the main window draws. The built-in look is `DefaultSkin`;
/// a `.wsz` loader can implement the same protocol.
protocol Skin: AnyObject {
    func image(for element: SkinElement) -> CGImage
    /// A 5×6 text glyph for the marquee and readouts. Expects `PixelFont.normalize`d input.
    func glyph(for character: Character) -> CGImage
    /// 24 visualizer colors in `viscolor.txt` order: background, grid dots,
    /// 16 spectrum colors from top to bottom, 5 oscilloscope colors, peak dots.
    var visColors: [CGColor] { get }
    /// 19 colors for the equalizer graph, top (+12 dB) to bottom (-12 dB).
    var eqGraphColors: [CGColor] { get }
    var playlistColors: PlaylistColors { get }
}

/// The playlist's text colors, as in a skin's `pledit.txt`.
struct PlaylistColors {
    var normal: CGColor
    var current: CGColor
    var normalBackground: CGColor
    var selectedBackground: CGColor
}

enum EQButton: Hashable {
    case on, auto, presets
}
