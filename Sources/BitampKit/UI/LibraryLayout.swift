import CoreGraphics

/// Where things sit in the Media Library window, in skin pixels.
enum LibraryLayout {
    static let defaultSize = CGSize(width: 475, height: 20 + 9 * 29 + 12)
    static let minSize = CGSize(width: 375, height: 20 + 5 * 29 + 12)
    /// It grows by the playlist's tiles: 25 across, 29 down.
    static let widthStep: CGFloat = 25
    static let heightStep = PlaylistLayout.heightStep

    static let sidebarWidth = 96
    /// The search box's height, and the sidebar's rows.
    static let boxHeight = 13
    static let sidebarRow = ListFont.lineHeight + 2
    /// The bar across the top of the pane: back, the page's title, Play and Add.
    static let barHeight = 15
    static let rowHeight = ListFont.lineHeight + 2
    static let shelfTitleHeight = 17
    static let cover = 44
    static let headerCover = 64
    static let headerHeight = headerCover + 8
    /// A cover and two lines under it.
    static let cell = CGSize(width: 55, height: 44 + 2 + 2 * ListFont.lineHeight + 4)
    /// The corner that resizes the window.
    static let gripSize = CGSize(width: 20, height: 20)

    static func snapped(_ size: CGSize) -> CGSize {
        func snap(_ value: CGFloat, _ minimum: CGFloat, _ step: CGFloat) -> CGFloat {
            minimum + max(0, ((value - minimum) / step).rounded()) * step
        }
        return CGSize(width: snap(size.width, minSize.width, widthStep), height: snap(size.height, minSize.height, heightStep))
    }

    /// The window's parts, for a frame of `size`.
    struct Parts {
        let content: CGRect
        let sidebar: CGRect
        let search: CGRect
        let sectionsTop: Int
        let dividerX: Int
        let pane: CGRect
        let bar: CGRect
        /// Where the page scrolls.
        let list: CGRect
        let scrollTrack: CGRect
        let grip: CGRect

        init(size: CGSize, gen: Bool) {
            content = PanelFrame.content(in: size, gen: gen)
            scrollTrack = PanelFrame.scrollTrack(in: size, gen: gen)
            sidebar = CGRect(x: content.minX, y: content.minY, width: CGFloat(sidebarWidth), height: content.height)
            search = CGRect(x: sidebar.minX + 2, y: sidebar.minY + 3, width: sidebar.width - 4, height: CGFloat(boxHeight))
            sectionsTop = Int(search.maxY) + 4
            dividerX = Int(sidebar.maxX) + 1
            let paneX = CGFloat(dividerX + 4)
            pane = CGRect(x: paneX, y: content.minY, width: scrollTrack.minX - 2 - paneX, height: content.height)
            bar = CGRect(x: pane.minX, y: pane.minY + 2, width: pane.width, height: CGFloat(barHeight))
            list = CGRect(x: pane.minX, y: bar.maxY + 2, width: pane.width, height: pane.maxY - bar.maxY - 2)
            grip = CGRect(x: size.width - gripSize.width, y: size.height - gripSize.height,
                          width: gripSize.width, height: gripSize.height)
        }
    }

    /// One piece of a laid-out page, `y` pixels from the top of the list.
    struct Block: Equatable {
        enum Kind: Equatable {
            case header
            case shelfTitle(String)
            /// The index of the track in the page's items.
            case track(Int)
            /// The indices of the places in one row of covers.
            case grid([Int])
        }

        let kind: Kind
        let y: Int
        let height: Int
    }

    /// Lays out `shelves` for a list `width` pixels wide: the header, if any, then each
    /// shelf's title, its tracks as rows and its places as rows of covers. Items are
    /// numbered in order across all shelves, as `PakPage.items` lists them.
    static func blocks(header: Bool, shelves: [PakShelf], width: Int) -> (blocks: [Block], height: Int) {
        var blocks: [Block] = []
        var y = 0
        func add(_ kind: Block.Kind, _ height: Int) {
            blocks.append(Block(kind: kind, y: y, height: height))
            y += height
        }
        if header { add(.header, headerHeight) }
        let columns = max(1, width / Int(cell.width))
        var index = 0
        for shelf in shelves {
            if let title = shelf.title { add(.shelfTitle(title), shelfTitleHeight) }
            var row: [Int] = []
            func flushRow() {
                if !row.isEmpty { add(.grid(row), Int(cell.height)) }
                row = []
            }
            for item in shelf.items {
                switch item {
                case .track:
                    flushRow()
                    add(.track(index), rowHeight)
                case .place:
                    row.append(index)
                    if row.count == columns { flushRow() }
                }
                index += 1
            }
            flushRow()
            y += 4
        }
        return (blocks, y)
    }
}

extension PakPage {
    /// Every item on the page, in order, as `LibraryLayout.blocks` numbers them.
    var items: [PakItem] {
        shelves.flatMap(\.items)
    }
}
