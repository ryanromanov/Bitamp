import Compression
import Foundation

/// Reads files out of a zip archive: stored or deflated entries, no encryption, no zip64.
/// That covers `.wsz` skins, which are ordinary zips of small bitmaps.
struct ZipArchive {
    struct Entry {
        let path: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int

        var isDirectory: Bool { path.hasSuffix("/") }
    }

    enum ZipError: Error {
        case notAZip, corrupt, unsupportedMethod(UInt16)
    }

    let entries: [Entry]
    private let bytes: [UInt8]

    init(data: Data) throws {
        bytes = [UInt8](data)
        entries = try Self.readCentralDirectory(bytes)
    }

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    func contents(of entry: Entry) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, Self.uint32(bytes, header) == 0x0403_4b50 else { throw ZipError.corrupt }
        let start = header + 30 + Int(Self.uint16(bytes, header + 26)) + Int(Self.uint16(bytes, header + 28))
        guard start + entry.compressedSize <= bytes.count else { throw ZipError.corrupt }
        let compressed = bytes[start..<(start + entry.compressedSize)]

        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            var output = [UInt8](repeating: 0, count: entry.uncompressedSize)
            // COMPRESSION_ZLIB is raw DEFLATE, which is what zip stores.
            let written = compressed.withUnsafeBufferPointer { source in
                compression_decode_buffer(
                    &output, output.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
            guard written == entry.uncompressedSize else { throw ZipError.corrupt }
            return Data(output)
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    private static func readCentralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        // The end-of-central-directory record is the last 22 bytes, plus up to 64 KB of comment.
        guard bytes.count >= 22 else { throw ZipError.notAZip }
        let earliest = max(0, bytes.count - 22 - 0xFFFF)
        guard let end = stride(from: bytes.count - 22, through: earliest, by: -1)
            .first(where: { uint32(bytes, $0) == 0x0605_4b50 })
        else { throw ZipError.notAZip }

        let count = Int(uint16(bytes, end + 10))
        var offset = Int(uint32(bytes, end + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, uint32(bytes, offset) == 0x0201_4b50 else { throw ZipError.corrupt }
            let nameLength = Int(uint16(bytes, offset + 28))
            let extraLength = Int(uint16(bytes, offset + 30))
            let commentLength = Int(uint16(bytes, offset + 32))
            guard offset + 46 + nameLength <= bytes.count else { throw ZipError.corrupt }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(
                path: name,
                method: uint16(bytes, offset + 10),
                compressedSize: Int(uint32(bytes, offset + 20)),
                uncompressedSize: Int(uint32(bytes, offset + 24)),
                localHeaderOffset: Int(uint32(bytes, offset + 42))))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func uint16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
