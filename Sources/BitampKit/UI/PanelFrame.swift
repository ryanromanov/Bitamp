import CoreGraphics

/// The frame around Bitamp's extra windows (Expansion Paks, Media Library): the skin's
/// generic window frame (`gen.bmp`) when it has one, else the playlist's title and side
/// tiles with a strip of its bottom tile. Both come from the skin, so `.wsz` skins dress it.
struct PanelFrame {
    let skin: Skin
    /// The window's size in skin pixels.
    let size: CGSize
    /// Shown in the title bar, in capitals.
    let title: String
    let active: Bool

    /// The playlist-tile frame's edges.
    static let top = 20
    static let bottom = 12
    static let left = 12
    /// The playlist's right tile is 20 wide; its scrollbar groove is the right 15 of it.
    static let rightTile = 20
    /// Content may cover the groove up to here when there's nothing to scroll.
    static let right = 7

    var usesGen: Bool { skin.gen != nil }

    /// Inside the frame. With playlist tiles, this covers the scrollbar groove; leave the
    /// groove out (`scrollTrack`) when there's something to scroll.
    var content: CGRect { Self.content(in: size, gen: usesGen) }
    var close: CGRect { Self.close(in: size, gen: usesGen) }
    var scrollTrack: CGRect { Self.scrollTrack(in: size, gen: usesGen) }

    static func content(in size: CGSize, gen: Bool) -> CGRect {
        if gen {
            return CGRect(x: GenArt.leftWidth, y: GenArt.topHeight, width: Int(size.width) - GenArt.leftWidth - GenArt.rightWidth,
                          height: Int(size.height) - GenArt.topHeight - GenArt.bottomHeight)
        }
        return CGRect(x: left, y: top, width: Int(size.width) - left - right, height: Int(size.height) - top - bottom)
    }

    /// The close button. A `gen.bmp` frame's edges are thinner.
    static func close(in size: CGSize, gen: Bool) -> CGRect {
        gen ? CGRect(x: size.width - 11, y: 3, width: 9, height: 9) : PlaylistLayout.close(in: size)
    }

    /// Where a scroll thumb runs: the playlist's groove, or just inside a `gen.bmp` frame's
    /// right edge.
    static func scrollTrack(in size: CGSize, gen: Bool) -> CGRect {
        let (top, bottom) = gen ? (GenArt.topHeight, GenArt.bottomHeight) : (top, bottom)
        return CGRect(x: Int(size.width) - (gen ? 16 : 15), y: top,
                      width: Int(PlaylistLayout.scrollThumb.width), height: Int(size.height) - top - bottom)
    }

    func draw(_ c: Canvas, closePressed: Bool) {
        if let gen = skin.gen {
            drawGen(c, gen, closePressed: closePressed)
        } else {
            drawPlaylistTiles(c, closePressed: closePressed)
        }
    }

    /// The playlist's top and side tiles, and a closing strip from its bottom tile.
    private func drawPlaylistTiles(_ c: Canvas, closePressed: Bool) {
        let (w, h) = (Int(size.width), Int(size.height))
        for x in stride(from: 0, to: w, by: 25) {
            c.draw(skin.image(for: .playlistBottomTile), x, h - Self.bottom)
        }
        for x in stride(from: 25, to: w - 25, by: 25) {
            c.draw(skin.image(for: .playlistTopTile(active: active)), x, 0)
        }
        c.draw(skin.image(for: .playlistTopLeft(active: active)), 0, 0)
        c.draw(skin.image(for: .playlistTopRight(active: active)), w - 25, 0)
        for y in stride(from: Self.top, to: h - Self.bottom, by: Int(PlaylistLayout.heightStep)) {
            c.draw(skin.image(for: .playlistLeftTile), 0, y)
            c.draw(skin.image(for: .playlistRightTile), w - Self.rightTile, y)
        }
        c.draw(skin.image(for: .playlistCloseButton(pressed: closePressed)), at: close.origin)
        drawTitle(c)
    }

    /// The skin's generic window frame, laid out like Webamp's: the title in its own
    /// font between two end pieces, with the fill stretching out to the corners.
    private func drawGen(_ c: Canvas, _ gen: GenArt, closePressed: Bool) {
        let (w, h) = (Int(size.width), Int(size.height))
        let top = gen.top(active: active)
        // The title box: 4px before the letters, 3px after.
        let titleWidth = gen.titleWidth(title) + 7
        let fill = max(0, w - 100 - titleWidth)
        let leftFill = fill / 2
        tile(c, top.centerFill, from: 0, to: w, y: 0)
        tile(c, top.fill, from: 25, to: 25 + leftFill, y: 0)
        tileFromRight(c, top.fill, from: w - 25 - (fill - leftFill), to: w - 25, y: 0)
        c.draw(top.left, 0, 0)
        c.draw(top.leftEnd, 25 + leftFill, 0)
        var x = 50 + leftFill + 4
        for character in title.uppercased() {
            if let letter = gen.letter(character, active: active) {
                c.draw(letter, x, GenArt.letterY)
                x += letter.width
            } else {
                x += GenArt.spaceWidth
            }
        }
        c.draw(top.rightEnd, w - 50 - (fill - leftFill), 0)
        c.draw(top.right, w - 25, 0)
        if closePressed {
            c.draw(gen.closePressed, at: close.origin)
        }

        // The sides, with their bottom pieces at the foot; then the bottom edge.
        let sideBottom = h - GenArt.bottomHeight
        for y in stride(from: GenArt.topHeight, to: sideBottom, by: gen.middleLeft.height) {
            c.draw(gen.middleLeft, 0, y)
            c.draw(gen.middleRight, w - GenArt.rightWidth, y)
        }
        c.draw(gen.middleLeftBottom, 0, sideBottom - gen.middleLeftBottom.height)
        c.draw(gen.middleRightBottom, w - GenArt.rightWidth, sideBottom - gen.middleRightBottom.height)
        tile(c, gen.bottomFill, from: 0, to: w, y: sideBottom)
        c.draw(gen.bottomLeft, 0, sideBottom)
        c.draw(gen.bottomRight, w - gen.bottomRight.width, sideBottom)
    }

    /// Repeats `image` across [from, to), clipping the last copy.
    private func tile(_ c: Canvas, _ image: CGImage, from: Int, to: Int, y: Int) {
        guard to > from else { return }
        c.context.saveGState()
        c.context.clip(to: CGRect(x: from, y: y, width: to - from, height: image.height))
        for x in stride(from: from, to: to, by: image.width) { c.draw(image, x, y) }
        c.context.restoreGState()
    }

    /// Like `tile`, but lined up with the right edge, as Webamp's right fill is.
    private func tileFromRight(_ c: Canvas, _ image: CGImage, from: Int, to: Int, y: Int) {
        guard to > from else { return }
        c.context.saveGState()
        c.context.clip(to: CGRect(x: from, y: y, width: to - from, height: image.height))
        var x = to - image.width
        while x + image.width > from {
            c.draw(image, x, y)
            x -= image.width
        }
        c.context.restoreGState()
    }

    /// The title in the middle of the title bar, styled like the playlist's title when the
    /// skin can draw it, or on a plate in the playlist's colors when it can't.
    private func drawTitle(_ c: Canvas) {
        let colors = skin.playlistColors
        if let image = skin.titleImage(title, active: active) {
            c.draw(image, (Int(size.width) - image.width) / 2, 0)
            return
        }
        let width = PixelFont.width(of: title) + 5
        let x = (Int(size.width) - width) / 2
        c.fill(x, 5, width, 10, colors.normalBackground)
        c.text(title, x + 3, 7, active ? colors.current : colors.normal)
    }
}
