import AppKit
import MetalKit

/// Draws the full-window visualizer, fed from the shared `SpectrumAnalyzer`.
///
/// Every visual is drawn small, at the skin's own pixel size, into a texture, then scaled up
/// with no smoothing, so it looks like the rest of the player. Most visuals are one fragment
/// shader over a full-screen triangle; Alchemy feeds back on itself, drawing into one of two
/// textures from the other. A later MilkDrop-style engine would be another visual built from
/// the same pieces.
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
        var levels: Float = 0
        /// How far the starfield has flown, which speeds up with the music.
        var travel: Float = 0
        /// How far through a shooting star is, 0 to 1, or -1 when there isn't one.
        var shoot: Float = -1
        /// Picks where the shooting star starts.
        var shootSeed: Float = 0
        /// How many entries of the star buffer to draw.
        var starCount: Float = 0
        /// How far Solar Sailing's shockwave has run, 0 to 1, or -1 when there isn't one.
        var ring: Float = -1
    }

    private let analyzer: SpectrumAnalyzer
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let format: MTLPixelFormat
    private var single: [FullVisual: MTLRenderPipelineState] = [:]
    private let feedbackStep: MTLRenderPipelineState
    private let present: MTLRenderPipelineState
    /// The small picture: what a single-pass visual draws into.
    private var scene: MTLTexture?
    /// Alchemy's two frames, drawn into in turn. Half-float, so a slow fade reaches black.
    private var feedback: [MTLTexture] = []
    private var feedbackIndex = 0

    private var start = CACurrentMediaTime()
    private var uniforms = Uniforms()
    private var detector = BeatDetector()
    private var shootingStarStart: TimeInterval = -.infinity
    private static let shootingStarDuration: TimeInterval = 0.28
    /// A shooting star needs a beat this many times the least that counts, and this long since
    /// the last one.
    private static let strongBeat: Float = 3
    private static let shootingStarGap: TimeInterval = 20
    /// Solar Sailing's shockwave ring: sent by a beat this hard, at most this often, and
    /// taking this long to run out.
    private static let ringBeat: Float = 2.4
    private static let ringGap: TimeInterval = 8
    private static let ringDuration: TimeInterval = 0.8
    private var ringStart: TimeInterval = -.infinity
    private var lastUpdate = CACurrentMediaTime()
    /// The last stretch of the analyzer, by how far the ship has travelled, for the star
    /// visuals: `historyBuckets` buckets of 0.01 travel for each of the 19 bands, as a ring.
    /// A star asks how loud its band was when it was born.
    private let history: MTLBuffer
    private var lastBucket = 0
    /// Solar Sailing's stars, written on the CPU a frame at a time into a ring of buffers, so one
    /// being drawn is never being written.
    private let starBuffers: [MTLBuffer]
    private var starFrame = 0
    /// How far the ship has gone, kept in double precision: a long listen would blur a float.
    private var travel: Double = 0
    private static let historyBuckets = 1024
    private(set) var visual: FullVisual = .barsAndWaves

    /// How many screen pixels make one pixel of the picture. The panel sets this to match the
    /// skin's pixels, and so does full screen unless that would be too many rows to draw; nil
    /// picks a size that gives about 200 rows.
    var pixelDivisor: Int?
    /// The skin's 24 analyzer colours (`viscolor.txt`), as RGBA.
    private var palette = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: 24)

    init?(view: MTKView, analyzer: SpectrumAnalyzer) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: VisualizerShaders.source, options: nil),
              let vertex = library.makeFunction(name: "vis_vertex") else { return nil }
        self.analyzer = analyzer
        self.device = device
        self.queue = queue
        format = view.colorPixelFormat
        let historyBytes = SpectrumAnalyzer.barCount * Self.historyBuckets * MemoryLayout<Float>.stride
        guard let history = device.makeBuffer(length: historyBytes, options: .storageModeShared) else { return nil }
        memset(history.contents(), 0, historyBytes)
        self.history = history
        let starBytes = StreakSky.total * MemoryLayout<StreakStar>.stride
        let buffers = (0..<4).compactMap { _ in device.makeBuffer(length: starBytes, options: .storageModeShared) }
        guard buffers.count == 4 else { return nil }
        starBuffers = buffers

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
            guard let state = pipeline(shader, .rgba16Float) else { return nil }
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

    /// Takes the picture's colours from a skin.
    func setPalette(_ colors: [CGColor]) {
        guard colors.count >= 24 else { return }
        palette = colors.prefix(24).map { color in
            let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color
            let c = rgb.components ?? [0, 0, 0, 1]
            return SIMD4(Float(c[0]), Float(c.count > 2 ? c[1] : c[0]), Float(c.count > 2 ? c[2] : c[0]), 1)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        feedback = []
        scene = nil
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer() else { return }
        updateUniforms()
        encode(into: buffer, target: drawable.texture)
        buffer.present(drawable)
        buffer.commit()
    }

    // MARK: - Passes

    /// The size of the small picture for a target `width` by `height` screen pixels.
    private func pictureSize(width: Int, height: Int) -> (Int, Int) {
        let divisor = max(1, pixelDivisor ?? Int((Double(height) / 200).rounded()))
        return (max(16, width / divisor), max(16, height / divisor))
    }

    private func texture(_ width: Int, _ height: Int, usage: MTLTextureUsage, storage: MTLStorageMode = .private) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = storage
        return device.makeTexture(descriptor: descriptor)
    }

    private func encode(into buffer: MTLCommandBuffer, target: MTLTexture) {
        let (width, height) = pictureSize(width: target.width, height: target.height)
        var uniforms = self.uniforms
        uniforms.resolution = SIMD2(Float(width), Float(height))
        uniforms.levels = visual.ditherLevels
        var bars = analyzer.bars
        var wave = analyzer.waveform
        var peaks = analyzer.peaks
        var palette = self.palette

        // Solar Sailing's stars: worked out here, drawn by the shader.
        var starBuffer: MTLBuffer?
        if visual == .solarSailing {
            starFrame = (starFrame + 1) % starBuffers.count
            let buffer = starBuffers[starFrame]
            let frame = StreakSky.Frame(resolution: uniforms.resolution, time: Double(uniforms.time), travel: travel,
                                        energy: uniforms.energy, beat: uniforms.beat)
            let count = StreakSky.stars(frame, bars: bars,
                                        history: history.contents().assumingMemoryBound(to: Float.self),
                                        rhoMin: 0.2, rhoSpan: 0.8,
                                        into: buffer.contents().assumingMemoryBound(to: StreakStar.self), capacity: StreakSky.total)
            uniforms.starCount = Float(count)
            starBuffer = buffer
        }

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
            encoder.setFragmentBytes(&palette, length: palette.count * MemoryLayout<SIMD4<Float>>.stride, index: 3)
            encoder.setFragmentBytes(&peaks, length: peaks.count * MemoryLayout<Float>.stride, index: 4)
            encoder.setFragmentBuffer(history, offset: 0, index: 5)
            if let starBuffer { encoder.setFragmentBuffer(starBuffer, offset: 0, index: 6) }
            if let input { encoder.setFragmentTexture(input, index: 0) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        let drawn: MTLTexture
        if let state = single[visual] {
            if scene.map({ ($0.width, $0.height) != (width, height) }) ?? true {
                scene = texture(width, height, usage: [.renderTarget, .shaderRead])
            }
            guard let scene else { return }
            pass(scene, state)
            drawn = scene
        } else {
            if feedback.count != 2 || (feedback[0].width, feedback[0].height) != (width, height) {
                let textures = (0..<2).compactMap { _ in texture(width, height, usage: [.renderTarget, .shaderRead]) }
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
            feedbackIndex = 1 - feedbackIndex
            drawn = destination
        }
        pass(target, present, input: drawn)
    }

    /// The current visual drawn off screen after `frames` frames, for tests and pictures.
    func snapshot(width: Int, height: Int, frames: Int = 1, shootingStar: Float? = nil) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        feedback = []
        scene = nil
        start = CACurrentMediaTime() - 5
        fillHistory()
        // One command buffer a frame, each finished before the next: the star buffers are
        // rewritten every frame.
        for frame in 0..<frames {
            guard let buffer = queue.makeCommandBuffer() else { return nil }
            updateUniforms()
            uniforms.time = 5 + Float(frame) / 60
            travel = 0.3 + Double(frame) / 60 * 0.3
            uniforms.travel = Float(travel)
            // The first look at a loud analyzer is always a beat; a picture wants only the star it asked for.
            uniforms.shoot = shootingStar ?? -1
            uniforms.ring = -1
            uniforms.shootSeed = 0.4
            encode(into: buffer, target: texture)
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
        return CGDataProvider(data: Data(pixels) as CFData).flatMap {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: $0, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    /// Writes the analyzer's levels for every bucket the ship has passed since the last frame.
    private func recordHistory() {
        let bars = analyzer.bars
        let slots = Self.historyBuckets
        let pointer = history.contents().bindMemory(to: Float.self, capacity: SpectrumAnalyzer.barCount * slots)
        let bucket = Int((uniforms.travel * 100).rounded(.down))
        let first = max(lastBucket + 1, bucket - slots + 1)
        for b in min(first, bucket)...bucket {
            for band in 0..<SpectrumAnalyzer.barCount { pointer[band * slots + (b & (slots - 1))] = bars[band] }
        }
        lastBucket = max(lastBucket, bucket)
    }

    /// Makes the whole history the analyzer's levels now, so a picture taken at once has stars.
    private func fillHistory() {
        let bars = analyzer.bars
        let slots = Self.historyBuckets
        let pointer = history.contents().bindMemory(to: Float.self, capacity: SpectrumAnalyzer.barCount * slots)
        for band in 0..<SpectrumAnalyzer.barCount {
            for b in 0..<slots { pointer[band * slots + b] = bars[band] }
        }
    }

    private func updateUniforms() {
        let bars = analyzer.bars
        func average(_ range: Range<Int>) -> Float { range.map { bars[$0] }.reduce(0, +) / Float(range.count) }
        let bass = average(0..<4), mid = average(4..<12), treble = average(12..<SpectrumAnalyzer.barCount)
        let now = CACurrentMediaTime()
        if let strength = detector.update(bars: bars, at: now) {
            uniforms.beat = 1
            // A strong beat, not too soon after the last shooting star, sends another.
            if strength >= Self.ringBeat, now - ringStart >= Self.ringGap { ringStart = now }
            if strength >= Self.strongBeat, now - shootingStarStart >= Self.shootingStarGap {
                shootingStarStart = now
                uniforms.shootSeed = Float.random(in: 0..<1)
            }
        } else {
            uniforms.beat *= 0.9
        }
        let ringProgress = (now - ringStart) / Self.ringDuration
        uniforms.ring = ringProgress >= 0 && ringProgress <= 1 ? Float(ringProgress) : -1
        let shot = (now - shootingStarStart) / Self.shootingStarDuration
        uniforms.shoot = shot >= 0 && shot <= 1 ? Float(shot) : -1
        travel += min(now - lastUpdate, 0.05) * Double(0.12 + 0.5 * (bass + mid + treble) / 3 + 0.3 * uniforms.beat)
        uniforms.travel = Float(travel)
        lastUpdate = now
        uniforms.time = Float(now - start)
        uniforms.bass = bass
        uniforms.mid = mid
        uniforms.treble = treble
        uniforms.energy = (bass + mid + treble) / 3
        recordHistory()
    }
}
