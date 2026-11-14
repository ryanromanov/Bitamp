import AppKit
import MetalKit

/// Draws the full-window visualizer, fed from the shared `SpectrumAnalyzer`. Most visuals
/// are one fragment shader over a full-screen triangle; Alchemy feeds back on itself, drawing
/// into one of two textures from the other and then to the screen. A later MilkDrop-style
/// engine would be another visual built from the same pieces.
///
/// The renderer only reads the analyzer. The main window's frame loop advances it, once a
/// frame, so the falloff speeds the user chose stay as they are.
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
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let format: MTLPixelFormat
    private var single: [FullVisual: MTLRenderPipelineState] = [:]
    private let feedbackStep: MTLRenderPipelineState
    private let present: MTLRenderPipelineState
    /// Alchemy's two frames, drawn into in turn. Half-float, so a slow fade reaches black.
    private var feedback: [MTLTexture] = []
    private var feedbackIndex = 0

    private var start = CACurrentMediaTime()
    private var uniforms = Uniforms()
    private var bassAverage: Float = 0
    private var sinceBeat = 0
    private(set) var visual: FullVisual = .barsAndWaves

    init?(view: MTKView, analyzer: SpectrumAnalyzer) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: VisualizerShaders.source, options: nil),
              let vertex = library.makeFunction(name: "vis_vertex") else { return nil }
        self.analyzer = analyzer
        self.device = device
        self.queue = queue
        format = view.colorPixelFormat

        func pipeline(_ name: String, _ pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
            guard let fragment = library.makeFunction(name: name) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        for visual in FullVisual.allCases {
            guard let shader = visual.shader else { continue }
            guard let state = pipeline(shader, view.colorPixelFormat) else { return nil }
            single[visual] = state
        }
        guard let step = pipeline("alchemy_step", .rgba16Float), let present = pipeline("present", view.colorPixelFormat) else { return nil }
        feedbackStep = step
        self.present = present
        super.init()
        view.device = device
        view.delegate = self
    }

    func select(_ new: FullVisual) {
        guard new != visual else { return }
        visual = new
        feedback = []  // Alchemy starts from black each time it's chosen.
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        feedback = []
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer() else { return }
        updateUniforms(size: view.drawableSize)
        encode(into: buffer, target: drawable.texture)
        buffer.present(drawable)
        buffer.commit()
    }

    // MARK: - Passes

    private func encode(into buffer: MTLCommandBuffer, target: MTLTexture) {
        var uniforms = self.uniforms
        var bars = analyzer.bars
        var wave = analyzer.waveform

        func pass(_ texture: MTLTexture, _ state: MTLRenderPipelineState, input: MTLTexture? = nil) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = texture
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(state)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&bars, length: bars.count * MemoryLayout<Float>.stride, index: 1)
            encoder.setFragmentBytes(&wave, length: wave.count * MemoryLayout<Float>.stride, index: 2)
            if let input { encoder.setFragmentTexture(input, index: 0) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        if let state = single[visual] {
            pass(target, state)
            return
        }
        let size = (target.width, target.height)
        if feedback.count != 2 || (feedback[0].width, feedback[0].height) != size {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size.0, height: size.1, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            let textures = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            guard textures.count == 2 else { return }
            feedback = textures
            feedbackIndex = 0
            // Private textures start with whatever was in memory, so clear both to black.
            for texture in textures {
                let descriptor = MTLRenderPassDescriptor()
                descriptor.colorAttachments[0].texture = texture
                descriptor.colorAttachments[0].loadAction = .clear
                descriptor.colorAttachments[0].storeAction = .store
                buffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
            }
        }
        let source = feedback[feedbackIndex], destination = feedback[1 - feedbackIndex]
        pass(destination, feedbackStep, input: source)
        pass(target, present, input: destination)
        feedbackIndex = 1 - feedbackIndex
    }

    /// The current visual drawn off screen after `frames` frames, for tests and pictures.
    func snapshot(width: Int, height: Int, frames: Int = 1) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else { return nil }
        feedback = []
        start = CACurrentMediaTime() - 5
        for frame in 0..<frames {
            updateUniforms(size: CGSize(width: width, height: height))
            uniforms.time = 5 + Float(frame) / 60
            encode(into: buffer, target: texture)
        }
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
