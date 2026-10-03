import Foundation

/// The files to play and the order to play them in. The playlist window (Phase 3)
/// will show and edit this; for now it backs previous/next, shuffle and repeat.
struct PlayQueue {
    private(set) var items: [URL] = []
    /// Indexes into `items` in play order: in sequence normally, a permutation when shuffled.
    private(set) var order: [Int] = []
    /// The current track's place in `order`.
    private(set) var position = 0
    private(set) var shuffled = false
    /// Wrap around at either end of the queue.
    var repeats = false
    /// The playing track was removed; `current` is the track that took its place, which
    /// plays next rather than being skipped.
    private var currentRemoved = false
    private var random: SplitMix64

    init(seed: UInt64 = .random(in: .min ... .max)) {
        random = SplitMix64(seed: seed)
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// The current track's index in `items`.
    var currentIndex: Int? {
        order.isEmpty ? nil : order[position]
    }

    var current: URL? {
        currentIndex.map { items[$0] }
    }

    /// The playing track's index, or nil when it has been removed from the queue.
    var playingIndex: Int? {
        currentRemoved ? nil : currentIndex
    }

    /// Replaces the queue. When shuffled, the first track is a random one.
    mutating func replace(with urls: [URL]) {
        items = urls
        currentRemoved = false
        rebuildOrder(keeping: nil)
    }

    /// Adds to the end of the queue, keeping the current track.
    mutating func append(_ urls: [URL]) {
        insert(urls, at: items.count)
    }

    /// Inserts before `index`, keeping the current track. When shuffled, the new tracks
    /// are mixed into the part of the order that hasn't played yet.
    mutating func insert(_ urls: [URL], at index: Int) {
        guard !urls.isEmpty else { return }
        let index = min(max(index, 0), items.count)
        let oldCount = items.count
        let newIndexes = Array(oldCount..<(oldCount + urls.count))
        items += urls
        if shuffled {
            let played = order.isEmpty ? [] : Array(order[...position])
            var upcoming = (order.isEmpty ? [] : Array(order[(position + 1)...])) + newIndexes
            upcoming.shuffle(using: &random)
            order = played + upcoming
        }
        var arrangement = Array(0..<oldCount)
        arrangement.insert(contentsOf: newIndexes, at: index)
        rearrange(arrangement)
    }

    mutating func remove(_ indexes: IndexSet) {
        rearrange(items.indices.filter { !indexes.contains($0) })
    }

    mutating func removeAll() {
        rearrange([])
    }

    /// Moves the items at `indexes` by `offset` places, as a block that stops at either end.
    /// Returns their new indexes.
    @discardableResult
    mutating func move(_ indexes: IndexSet, by offset: Int) -> IndexSet {
        guard let first = indexes.first, let last = indexes.last else { return indexes }
        let offset = min(max(offset, -first), items.count - 1 - last)
        guard offset != 0 else { return indexes }
        var arrangement = [Int?](repeating: nil, count: items.count)
        for index in indexes { arrangement[index + offset] = index }
        var others = items.indices.filter { !indexes.contains($0) }.makeIterator()
        rearrange(arrangement.map { $0 ?? others.next()! })
        return IndexSet(indexes.map { $0 + offset })
    }

    /// Sorts by `key` in Finder order (numbers compare by value).
    mutating func sort(by key: (URL) -> String) {
        let keys = items.map(key)
        rearrange(items.indices.sorted { keys[$0].localizedStandardCompare(keys[$1]) == .orderedAscending })
    }

    mutating func reverse() {
        rearrange(items.indices.reversed())
    }

    /// Shuffles the list itself, which is different from shuffled play order.
    mutating func randomize() {
        var arrangement = Array(items.indices)
        arrangement.shuffle(using: &random)
        rearrange(arrangement)
    }

    /// Makes the item at `index` current.
    mutating func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        currentRemoved = false
        if shuffled {
            rebuildOrder(keeping: index)
        } else {
            position = index
        }
    }

    mutating func setShuffled(_ shuffled: Bool) {
        guard shuffled != self.shuffled else { return }
        self.shuffled = shuffled
        rebuildOrder(keeping: currentIndex)
    }

    /// Moves to the next track. Returns nil, and stays put, at the end unless repeating.
    @discardableResult
    mutating func next() -> URL? {
        guard !order.isEmpty else { return nil }
        if currentRemoved {
            currentRemoved = false
            return current
        }
        if position + 1 < order.count {
            position += 1
        } else if repeats {
            if shuffled {
                // A fresh order each time around, without playing the last track twice in a row.
                let last = order[position]
                rebuildOrder(keeping: nil)
                if order.count > 1 && order[0] == last { order.swapAt(0, 1) }
            }
            position = 0
        } else {
            return nil
        }
        return current
    }

    /// Moves to the previous track. At the start it wraps when repeating and otherwise stays.
    @discardableResult
    mutating func previous() -> URL? {
        guard !order.isEmpty else { return nil }
        currentRemoved = false
        if position > 0 {
            position -= 1
        } else if repeats {
            position = order.count - 1
        }
        return current
    }

    /// Rebuilds `items` from `arrangement`, the old indexes of the items to keep in their
    /// new order. Keeps the current track and, when shuffled, the play order.
    private mutating func rearrange(_ arrangement: [Int]) {
        var newIndex: [Int: Int] = [:]
        for (new, old) in arrangement.enumerated() { newIndex[old] = new }
        let oldOrder = order
        let oldPosition = position
        let oldCurrent = currentIndex

        items = arrangement.map { items[$0] }
        order = shuffled ? oldOrder.compactMap { newIndex[$0] } : Array(items.indices)

        var current: Int?
        if let oldCurrent, let kept = newIndex[oldCurrent] {
            current = kept
        } else if oldCurrent != nil {
            // The current track went away: whatever was due next takes its place.
            current = oldOrder[(oldPosition + 1)...].lazy.compactMap { newIndex[$0] }.first
            currentRemoved = current != nil
            if current == nil { current = order.last }
        }
        if items.isEmpty { currentRemoved = false }
        position = current.flatMap { order.firstIndex(of: $0) } ?? 0
    }

    /// Rebuilds the play order. A kept track goes first when shuffling, so it plays on uninterrupted.
    private mutating func rebuildOrder(keeping index: Int?) {
        var order = Array(items.indices)
        if shuffled {
            order.shuffle(using: &random)
            if let index, let at = order.firstIndex(of: index) { order.swapAt(0, at) }
        }
        self.order = order
        position = index.flatMap { order.firstIndex(of: $0) } ?? 0
    }
}

/// A small seedable generator, so shuffles can be reproduced in tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
