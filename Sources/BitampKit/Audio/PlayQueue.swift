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

    /// Replaces the queue. When shuffled, the first track is a random one.
    mutating func replace(with urls: [URL]) {
        items = urls
        rebuildOrder(keeping: nil)
    }

    /// Adds to the end of the queue, keeping the current track.
    mutating func append(_ urls: [URL]) {
        let wasEmpty = items.isEmpty
        let newIndexes = items.count..<(items.count + urls.count)
        items += urls
        if wasEmpty || !shuffled {
            order += newIndexes
        } else {
            // Mix the new tracks into what hasn't played yet.
            var upcoming = Array(order[(position + 1)...]) + newIndexes
            upcoming.shuffle(using: &random)
            order = Array(order[...position]) + upcoming
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
        if position > 0 {
            position -= 1
        } else if repeats {
            position = order.count - 1
        }
        return current
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
