import AppKit
import MetalKit

/// Draws the full-window visualizer: one fragment shader per visual over a full-screen
/// triangle, fed from the shared `SpectrumAnalyzer`.
@MainActor
final class VisualizerRenderer: NSObject, MTKViewDelegate {
    struct Uniforms {
        var resolution: SIMD2<Float> = .zero
        var time: Float = 0
        var bass: Float = 0
        var mid: Float = 0
        var treble: Float = 0
        var beat: Float = 0
        var energy: Float = 0
    }

    private let analyzer: SpectrumAnalyzer
    private let queue: MTLCommandQueue
    private var pipelines: [MTLRenderPipelineState] = []
    private let start = CACurrentMediaTime()
    private var uniforms = Uniforms()
    private var bassAverage: Float = 0
    private var sinceBeat = 0
    private(set) var index = 0
    var onChange: (() -> Void)?

    var count: Int { pipelines.count }
    var name: String { VisualizerShaders.visuals[index].name }

    init?(view: MTKView, analyzer: SpectrumAnalyzer) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: VisualizerShaders.source, options: nil),
              let vertex = library.makeFunction(name: "vis_vertex") else { return nil }
        self.analyzer = analyzer
        self.queue = queue
        for visual in VisualizerShaders.visuals {
            guard let fragment = library.makeFunction(name: visual.function) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            pipelines.append(state)
        }
        super.init()
        view.device = device
        view.delegate = self
    }

    func select(_ newIndex: Int) {
        let wrapped = (newIndex % count + count) % count
        guard wrapped != index else { return }
        index = wrapped
        onChange?()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        updateUniforms(size: view.drawableSize)
        encode(into: encoder)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func encode(into encoder: MTLRenderCommandEncoder) {
        var uniforms = self.uniforms
        var bars = analyzer.bars
        var wave = analyzer.waveform
        encoder.setRenderPipelineState(pipelines[index])
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&bars, length: bars.count * MemoryLayout<Float>.stride, index: 1)
        encoder.setFragmentBytes(&wave, length: wave.count * MemoryLayout<Float>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// The current visual drawn off screen, for tests and the README pictures.
    func snapshot(width: Int, height: Int, time: Float? = nil) -> CGImage? {
        let device = queue.device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        updateUniforms(size: CGSize(width: width, height: height))
        if let time { uniforms.time = time }
        encode(into: encoder)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
        return CGDataProvider(data: Data(pixels) as CFData).flatMap {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: $0, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    private func updateUniforms(size: CGSize) {
        let bars = analyzer.bars
        func average(_ range: Range<Int>) -> Float { range.map { bars[$0] }.reduce(0, +) / Float(range.count) }
        let bass = average(0..<4), mid = average(4..<12), treble = average(12..<SpectrumAnalyzer.barCount)
        // A beat is the bass jumping well above its recent average.
        sinceBeat += 1
        if bass > 0.2, bass > bassAverage * 1.35, sinceBeat > 12 {
            uniforms.beat = 1
            sinceBeat = 0
        } else {
            uniforms.beat *= 0.9
        }
        bassAverage += (bass - bassAverage) * 0.05
        uniforms.resolution = SIMD2(Float(size.width), Float(size.height))
        uniforms.time = Float(CACurrentMediaTime() - start)
        uniforms.bass = bass
        uniforms.mid = mid
        uniforms.treble = treble
        uniforms.energy = (bass + mid + treble) / 3
    }
}
