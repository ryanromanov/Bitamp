import AVFoundation
import CoreAudio
import Testing
@testable import BitampKit

@Suite struct PakAudioListenerTests {
    /// An audio buffer list holding `samples` in one buffer, as the tap delivers stereo.
    private func withBufferList<R>(_ samples: [Float], _ body: (UnsafeMutableAudioBufferListPointer) -> R) -> R {
        var samples = samples
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        return samples.withUnsafeMutableBytes { bytes in
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
            return body(list)
        }
    }

    @available(macOS 14.2, *)
    @Test func splitsInterleavedStereoIntoChannels() throws {
        let buffer = try #require(withBufferList([0.1, -0.1, 0.2, -0.2, 0.3, -0.3]) {
            ProcessTap.planarBuffer($0, channels: 2, interleaved: true, sampleRate: 48_000)
        })
        #expect(buffer.frameLength == 3)
        #expect(buffer.format.sampleRate == 48_000 && buffer.format.channelCount == 2)
        let channels = try #require(buffer.floatChannelData)
        #expect(Array(UnsafeBufferPointer(start: channels[0], count: 3)) == [0.1, 0.2, 0.3])
        #expect(Array(UnsafeBufferPointer(start: channels[1], count: 3)) == [-0.1, -0.2, -0.3])
        #expect(ProcessTap.isAudible(buffer))
    }

    @available(macOS 14.2, *)
    @Test func silenceIsNotAudible() throws {
        let buffer = try #require(withBufferList([Float](repeating: 0, count: 1024)) {
            ProcessTap.planarBuffer($0, channels: 2, interleaved: true, sampleRate: 48_000)
        })
        #expect(buffer.frameLength == 512)
        #expect(!ProcessTap.isAudible(buffer))
        #expect(withBufferList([]) { ProcessTap.planarBuffer($0, channels: 2, interleaved: true, sampleRate: 48_000) } == nil)
    }

    /// The analyzer reads the converted buffer: a loud 1 kHz tone lights the bars around it.
    @available(macOS 14.2, *)
    @Test func feedsTheAnalyzer() throws {
        let tone = (0..<2048).flatMap { frame -> [Float] in
            let sample = Float(sin(2 * Double.pi * 1000 * Double(frame) / 48_000)) * 0.8
            return [sample, sample]
        }
        let analyzer = SpectrumAnalyzer()
        analyzer.sampleRate = 48_000
        let buffer = try #require(withBufferList(tone) {
            ProcessTap.planarBuffer($0, channels: 2, interleaved: true, sampleRate: 48_000)
        })
        analyzer.process(buffer)
        analyzer.advance()
        #expect(analyzer.bars.max() ?? 0 > 0.8)
    }
}
