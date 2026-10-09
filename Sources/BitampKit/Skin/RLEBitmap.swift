import CoreGraphics
import Foundation

/// Decodes run-length encoded `.bmp` files (RLE8 and RLE4), which some classic skins use,
/// Winamp's own base skin among them. ImageIO puts some of their rows in the wrong place,
/// so these are decoded here; uncompressed bitmaps still go through ImageIO.
enum RLEBitmap {
    /// The bitmap as an image, or nil if `data` isn't an RLE8 or RLE4 bitmap this can read.
    static func decode(_ data: Data) -> CGImage? {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard bytes.count >= 54, bytes[0] == 0x42, bytes[1] == 0x4D else { return nil }  // "BM"
        let pixelOffset = u32(10), headerSize = u32(14)
        let width = u32(18), height = Int(Int32(truncatingIfNeeded: u32(22)))
        let bitsPerPixel = u16(28), compression = u32(30)
        // RLE bitmaps are always stored bottom-up, so their height is positive.
        guard headerSize >= 40, width > 0, height > 0, width <= 4096, height <= 4096,
              (compression == 1 && bitsPerPixel == 8) || (compression == 2 && bitsPerPixel == 4)
        else { return nil }

        let paletteStart = 14 + headerSize
        var paletteCount = u32(46)
        if paletteCount == 0 { paletteCount = 1 << bitsPerPixel }
        guard paletteStart + paletteCount * 4 <= bytes.count, pixelOffset < bytes.count else { return nil }
        let palette: [(UInt8, UInt8, UInt8)] = (0..<paletteCount).map {
            let at = paletteStart + $0 * 4
            return (bytes[at + 2], bytes[at + 1], bytes[at])  // Stored as blue, green, red.
        }

        // Palette indices, top row first. Pixels the encoding skips stay at index 0.
        var indices = [UInt8](repeating: 0, count: width * height)
        var x = 0, row = 0  // `row` counts up from the bottom of the image.
        func put(_ index: UInt8) {
            if x < width && row < height { indices[(height - 1 - row) * width + x] = index }
            x += 1
        }
        var i = pixelOffset
        decoding: while i + 1 < bytes.count {
            let count = Int(bytes[i]), value = bytes[i + 1]
            i += 2
            if count > 0 {
                // A run: `count` pixels of one index, or of two alternating nibbles in RLE4.
                for n in 0..<count {
                    put(bitsPerPixel == 8 ? value : (n % 2 == 0 ? value >> 4 : value & 0x0F))
                }
                continue
            }
            switch value {
            case 0:  // End of line.
                x = 0
                row += 1
            case 1:  // End of bitmap.
                break decoding
            case 2:  // Delta: move right and up.
                guard i + 1 < bytes.count else { break decoding }
                x += Int(bytes[i])
                row += Int(bytes[i + 1])
                i += 2
            default:  // Absolute mode: `value` literal pixels, padded to an even byte count.
                let length = bitsPerPixel == 8 ? Int(value) : (Int(value) + 1) / 2
                guard i + length <= bytes.count else { break decoding }
                for n in 0..<Int(value) {
                    if bitsPerPixel == 8 {
                        put(bytes[i + n])
                    } else {
                        let byte = bytes[i + n / 2]
                        put(n % 2 == 0 ? byte >> 4 : byte & 0x0F)
                    }
                }
                i += length + length % 2
            }
        }

        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for (pixel, index) in indices.enumerated() {
            let color = Int(index) < palette.count ? palette[Int(index)] : (0, 0, 0)
            rgba[pixel * 4] = color.0
            rgba[pixel * 4 + 1] = color.1
            rgba[pixel * 4 + 2] = color.2
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
