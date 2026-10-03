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
}
