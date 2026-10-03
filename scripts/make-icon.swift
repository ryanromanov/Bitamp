// Draws Bitamp's app icon, a pixel-art stick figure with headphones on a little LCD,
// and writes it as an .icns file.
//
//     swift scripts/make-icon.swift Bitamp.app/Contents/Resources/AppIcon.icns
//
// The art is a 32×32 grid. Larger sizes scale it up with hard edges, 32 pixels is 1:1,
// and only the 16-pixel size is averaged down.

import AppKit

let grid = 32

enum Pixel {
    case color(UInt32)
    case shadow
}

var pixels = [[Pixel?]](repeating: [Pixel?](repeating: nil, count: grid), count: grid)

func set(_ x: Int, _ y: Int, _ pixel: Pixel) {
    guard (0..<grid).contains(x), (0..<grid).contains(y) else { return }
    pixels[y][x] = .some(pixel)
}

func fill(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ color: UInt32) {
    for row in y..<(y + height) { for column in x..<(x + width) { set(column, row, .color(color)) } }
}

// The default skin's palette.
let outline: UInt32 = 0x0e0f14, face: UInt32 = 0x2b2e39, faceLight: UInt32 = 0x4c5265, faceDark: UInt32 = 0x1a1c23
let lcd: UInt32 = 0x040b06, lcdGhost: UInt32 = 0x0e2415, green: UInt32 = 0x3ef06a
let amber: UInt32 = 0xffb23e, amberDark: UInt32 = 0xb8741a

/// The rounded tile: a 27-pixel superellipse (the shape of macOS icons) centered on
/// column 15, with a bevel and a shadow underneath. The odd width gives the art a single
/// center column.
func tile() {
    let (x0, y0, size) = (2, 2, 27)
    func inside(_ x: Int, _ y: Int) -> Bool {
        let center = Double(size) / 2 - 0.5
        let dx = abs(Double(x - x0) - center) / (Double(size) / 2)
        let dy = abs(Double(y - y0) - center) / (Double(size) / 2)
        return pow(dx, 5) + pow(dy, 5) <= 1
    }
    for y in 0..<grid {
        for x in 0..<grid {
            if inside(x, y) {
                let edge = !inside(x - 1, y) || !inside(x + 1, y) || !inside(x, y - 1) || !inside(x, y + 1)
                let lit = !inside(x, y - 2) || !inside(x - 2, y)
                let shaded = !inside(x, y + 2) || !inside(x + 2, y)
                set(x, y, .color(edge ? outline : lit ? faceLight : shaded ? faceDark : face))
            } else if inside(x, y - 1) {
                set(x, y, .shadow)
            }
        }
    }
}

/// The LCD: 21×21 at (5, 5), recessed, with the dim dot grid of the player's displays.
func screen() {
    let (x, y, size) = (5, 5, 21)
    fill(x - 1, y - 1, size + 2, size + 2, faceLight)
    fill(x - 1, y - 1, size + 1, size + 1, outline)
    fill(x, y, size, size, lcd)
    for row in stride(from: y + 1, to: y + size, by: 2) {
        for column in stride(from: x + 1, to: x + size, by: 2) { fill(column, row, 1, 1, lcdGhost) }
    }
}

/// The stick figure. Its spine is column `cx`; `top` is the first row of its head.
func figure(cx: Int, top: Int) {
    let head = ["..###..", ".#...#.", "#.....#", "#.....#", "#.....#", ".#...#.", "..###.."]
    for (row, bits) in head.enumerated() {
        for (column, bit) in bits.enumerated() where bit == "#" { fill(cx - 3 + column, top + row, 1, 1, green) }
    }

    // Headphones: the band over the head, then an ear cup on each side.
    fill(cx - 2, top - 2, 5, 1, amber)
    fill(cx - 3, top - 1, 1, 1, amber); fill(cx + 3, top - 1, 1, 1, amber)
    fill(cx - 4, top, 1, 2, amber); fill(cx + 4, top, 1, 2, amber)
    fill(cx - 5, top + 2, 2, 3, amber); fill(cx + 4, top + 2, 2, 3, amber)
    fill(cx - 5, top + 4, 1, 1, amberDark); fill(cx + 5, top + 4, 1, 1, amberDark)

    let neck = top + 7, torso = 5
    fill(cx, neck, 1, torso + 1, green)

    // Left arm hangs down. The right one bends up so the hand rests on the ear cup.
    let shoulder = neck + 2
    for i in 1...4 { fill(cx - i, shoulder + i - 1, 1, 1, green) }
    fill(cx + 1, shoulder, 2, 1, green)
    fill(cx + 3, shoulder - 1, 1, 1, green); fill(cx + 4, shoulder - 2, 1, 1, green)
    fill(cx + 5, shoulder - 4, 1, 2, green)

    let hip = neck + torso
    for i in 1...4 {
        fill(cx - i, hip + i, 1, 1, green)
        fill(cx + i, hip + i, 1, 1, green)
    }
    fill(cx - 5, hip + 4, 1, 1, green); fill(cx + 5, hip + 4, 1, 1, green)
}

/// An eighth note, 5×6: stem, curled flag and oval head.
func note(_ x: Int, _ y: Int) {
    fill(x + 2, y, 1, 5, green)
    fill(x + 3, y + 1, 1, 1, green); fill(x + 4, y + 2, 1, 2, green)
    fill(x, y + 4, 3, 2, green)
}

tile()
screen()
figure(cx: 15, top: 8)
note(5, 5)
note(21, 15)

// MARK: - Output

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

let art: CGImage = {
    let c = context(grid)
    for y in 0..<grid {
        for x in 0..<grid {
            switch pixels[y][x] {
            case .color(let hex)?:
                c.setFillColor(CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                                       blue: CGFloat(hex & 0xff) / 255, alpha: 1))
            case .shadow?:
                c.setFillColor(CGColor(gray: 0, alpha: 0.35))
            case nil:
                continue
            }
            c.fill(CGRect(x: x, y: grid - 1 - y, width: 1, height: 1))
        }
    }
    return c.makeImage()!
}()

func png(_ size: Int) -> Data {
    let c = context(size)
    c.interpolationQuality = size < grid ? .high : .none
    c.draw(art, in: CGRect(x: 0, y: 0, width: size, height: size))
    return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift scripts/make-icon.swift <output.icns>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try png(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
