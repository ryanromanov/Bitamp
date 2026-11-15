import Foundation
import Metal

typealias AudioView = MilkAudio

/// What the music is doing, as the engine wants it: the analyzer's bars and its scope trace.
struct MilkAudio {
    var bars: [Float]
    var waveform: [Float]
}

/// Plays a MilkDrop preset: runs its code each frame, warps last frame's picture through a
/// mesh the code shapes, draws its waves and shapes on top, and composites the result.
///
/// Picture space follows MilkDrop: x runs left to right and y top to bottom for the warp mesh,
/// while waves and shapes put y = 1 at the top.
@MainActor
final class MilkdropEngine {
    static let meshWidth = 48
    static let meshHeight = 36

    private struct Vertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
        var color: SIMD4<Float>
    }

    private struct Composite {
        var echoZoom: Float = 1
        var echoAlpha: Float = 0
        var echoOrient: Float = 0
        var gamma: Float = 1
        var brighten: Float = 0
        var darken: Float = 0
        var solarize: Float = 0
        var invert: Float = 0
    }

    private struct Batch {
        var additive: Bool
        var start: Int
        var count: Int
    }

    /// Names every context knows, which the engine fills in each frame.
    private static let frameInputs = ["time", "fps", "frame", "bass", "mid", "treb", "bass_att", "mid_att", "treb_att", "progress",
                                      "meshx", "meshy", "pixelsx", "pixelsy", "aspectx", "aspecty"]
    private static let warpNames = ["zoom", "zoomexp", "rot", "warp", "cx", "cy", "dx", "dy", "sx", "sy"]

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let warpPipeline: MTLRenderPipelineState
    private let alphaPipeline: MTLRenderPipelineState
    private let additivePipeline: MTLRenderPipelineState
    private let library: MTLLibrary
    private let vertexFunction: MTLFunction
    private var compositePipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let clampSampler: MTLSamplerState
    private let wrapSampler: MTLSamplerState
    private struct UserVertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
        var uvOrig: SIMD2<Float>
        var radAng: SIMD2<Float>
        var color: SIMD4<Float>
    }

    private var userWarp: MilkUserShader?
    private var userComposite: MilkUserShader?
    private let userWarpVertex: MTLFunction
    private let userCompVertex: MTLFunction
    private let textures: MilkTextures
    private var userMesh: [MTLBuffer] = []
    private var compMesh: [MTLBuffer] = []
    private var randomPreset = SIMD4<Float>(0.3, 0.6, 0.2, 0.8)
    private var frames: [MTLTexture] = []
    private var current = 0
    private var meshBuffers: [MTLBuffer] = []
    private var drawBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private static let maxDrawVertices = 120_000

    private(set) var preset = MilkPreset(text: "")
    private let frameContext = MilkContext()
    private let pixelContext = MilkContext()
    private var waveContexts: [MilkContext] = []
    private var shapeContexts: [MilkContext] = []
    private var perFrame: MilkProgram?
    private var perPixel: MilkProgram?
    private var waveFrame: [MilkProgram?] = []
    private var wavePoint: [MilkProgram?] = []
    private var shapeFrame: [MilkProgram?] = []
    /// Why the last preset's code didn't compile, if it didn't.
    private(set) var problems: [String] = []
    func frameValue(_ name: String) -> Double { frameContext[name] }

    /// For debugging a preset: parts to leave out ("wave", "customwaves", "shapes", "borders", "echo").
    var skipping: Set<String> = []

    private var levels = LevelTracker()
    private var frameNumber = 0
    private var presetStart: Double = 0
    private var size = (width: 0, height: 0)

    /// Frames clamp at 1 as MilkDrop's do, but keep 16 bits, so a slow decay still reaches black.
    private let format = MTLPixelFormat.rgba16Unorm

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: MilkdropShaders.source, options: nil),
              let vertex = library.makeFunction(name: "milk_vertex"),
              let warpVertex = library.makeFunction(name: "milk_user_vertex_warp"),
              let compVertex = library.makeFunction(name: "milk_user_vertex_comp"),
              let textures = MilkTextures(device: device) else { return nil }
        self.device = device
        self.queue = queue
        self.library = library
        self.userWarpVertex = warpVertex
        self.userCompVertex = compVertex
        self.textures = textures
        self.vertexFunction = vertex
        func pipeline(_ fragment: String, blend: Bool, additive: Bool = false) -> MTLRenderPipelineState? {
            guard let function = library.makeFunction(name: fragment) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = function
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .rgba16Unorm
            if blend {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let warp = pipeline("milk_warp", blend: false), let alpha = pipeline("milk_flat", blend: true),
              let additive = pipeline("milk_flat", blend: true, additive: true) else { return nil }
        warpPipeline = warp
        alphaPipeline = alpha
        additivePipeline = additive
        func sampler(_ address: MTLSamplerAddressMode) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            descriptor.sAddressMode = address
            descriptor.tAddressMode = address
            return device.makeSamplerState(descriptor: descriptor)
        }
        guard let clamp = sampler(.clampToEdge), let wrap = sampler(.repeat) else { return nil }
        clampSampler = clamp
        wrapSampler = wrap
        let meshBytes = Self.meshWidth * Self.meshHeight * 6 * MemoryLayout<Vertex>.stride
        let drawBytes = Self.maxDrawVertices * MemoryLayout<Vertex>.stride
        meshBuffers = (0..<3).compactMap { _ in device.makeBuffer(length: meshBytes, options: .storageModeShared) }
        drawBuffers = (0..<3).compactMap { _ in device.makeBuffer(length: drawBytes, options: .storageModeShared) }
        let userBytes = Self.meshWidth * Self.meshHeight * 6 * MemoryLayout<UserVertex>.stride
        userMesh = (0..<3).compactMap { _ in device.makeBuffer(length: userBytes, options: .storageModeShared) }
        compMesh = (0..<3).compactMap { _ in device.makeBuffer(length: userBytes, options: .storageModeShared) }
        guard meshBuffers.count == 3, drawBuffers.count == 3, userMesh.count == 3, compMesh.count == 3 else { return nil }
    }

    // MARK: - Loading

    /// Starts a preset: compiles its code and runs its init code.
    func load(_ new: MilkPreset, warpSource: String? = nil, compositeSource: String? = nil, at time: Double = 0) {
        preset = new
        problems = []
        randomPreset = SIMD4(Float.random(in: 0..<1), Float.random(in: 0..<1), Float.random(in: 0..<1), Float.random(in: 0..<1))
        userWarp = nil
        userComposite = nil
        var failure = ""
        if let warpSource {
            userWarp = MilkUserShader(device: device, source: warpSource, kind: .warp, vertex: userWarpVertex, error: &failure)
            if userWarp == nil { problems.append("warp shader: \(failure)") }
        }
        if let compositeSource {
            userComposite = MilkUserShader(device: device, source: compositeSource, kind: .composite, vertex: userCompVertex, error: &failure)
            if userComposite == nil { problems.append("composite shader: \(failure)") }
        }
        presetStart = time
        frameNumber = 0
        levels = LevelTracker()
        frames = []
        MilkContext.resetShared()
        frameContext.reset()
        pixelContext.reset()
        func compile(_ code: String, _ context: MilkContext, _ label: String) -> MilkProgram? {
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            do { return try MilkProgram(code, in: context) } catch {
                problems.append("\(label): \(error)")
                return nil
            }
        }
        // Names the engine reads back have to exist before the code that sets them is compiled.
        for name in Self.frameInputs + Self.warpNames { _ = frameContext.slot(name); _ = pixelContext.slot(name) }
        compile(new.perFrameInit, frameContext, "per_frame_init")?.run()
        perFrame = compile(new.perFrame, frameContext, "per_frame")
        perPixel = compile(new.perPixel, pixelContext, "per_pixel")
        waveContexts = (0..<4).map { _ in MilkContext() }
        shapeContexts = (0..<4).map { _ in MilkContext() }
        waveFrame = []
        wavePoint = []
        shapeFrame = []
        for i in 0..<4 {
            let wave = new.waves[i], shape = new.shapes[i]
            if wave.enabled {
                setWaveDefaults(waveContexts[i], wave)
                compile(wave.initCode, waveContexts[i], "wave \(i) init")?.run()
            }
            waveFrame.append(wave.enabled ? compile(wave.perFrame, waveContexts[i], "wave \(i) per_frame") : nil)
            wavePoint.append(wave.enabled ? compile(wave.perPoint, waveContexts[i], "wave \(i) per_point") : nil)
            if shape.enabled {
                setShapeDefaults(shapeContexts[i], shape)
                compile(shape.initCode, shapeContexts[i], "shape \(i) init")?.run()
            }
            shapeFrame.append(shape.enabled ? compile(shape.perFrame, shapeContexts[i], "shape \(i) per_frame") : nil)
        }
    }

    private func setWaveDefaults(_ c: MilkContext, _ wave: MilkPreset.Wave) {
        let n = wave.numbers
        c["samples"] = n["samples"] ?? 512
        c["r"] = n["r"] ?? 1
        c["g"] = n["g"] ?? 1
        c["b"] = n["b"] ?? 1
        c["a"] = n["a"] ?? 1
    }

    private func setShapeDefaults(_ c: MilkContext, _ shape: MilkPreset.Shape) {
        for key in ["sides", "x", "y", "rad", "ang", "r", "g", "b", "a", "r2", "g2", "b2", "a2", "border_r", "border_g", "border_b",
                    "border_a", "additive", "textured", "tex_zoom", "tex_ang", "num_inst"] {
            c[key] = shape.numbers[key == "num_inst" ? "num_inst" : key] ?? 0
        }
        if shape.numbers["num_inst"] == nil { c["num_inst"] = 1 }
        c["thick"] = shape.numbers["thickoutline"] ?? 0
    }

    // MARK: - Frames

    /// Draws one frame of the preset into `target`, which is `width` by `height`.
    func render(audio: MilkAudio, time: Double, deltaTime: Double, into target: MTLTexture) {
        let width = target.width, height = target.height
        if frames.count != 2 || size != (width, height) { makeFrames(width: width, height: height) }
        guard frames.count == 2, let buffer = queue.makeCommandBuffer() else { return }
        let aspectX = Float(width > height ? 1 : Double(width) / Double(height))
        let aspectY = Float(height > width ? 1 : Double(height) / Double(width))
        let presetTime = time - presetStart
        let measured = levels.update(audio: audio, deltaTime: deltaTime)

        // The preset's own settings, then its code on top.
        let c = frameContext
        let p = preset
        func set(_ name: String, _ value: Double) { c[name] = value }
        set("time", presetTime)
        set("fps", deltaTime > 0 ? 1 / deltaTime : 60)
        set("frame", Double(frameNumber))
        set("bass", Double(measured.bass)); set("mid", Double(measured.mid)); set("treb", Double(measured.treb))
        set("bass_att", Double(measured.bassAtt)); set("mid_att", Double(measured.midAtt)); set("treb_att", Double(measured.trebAtt))
        set("progress", 0)
        set("meshx", Double(Self.meshWidth)); set("meshy", Double(Self.meshHeight))
        set("pixelsx", Double(width)); set("pixelsy", Double(height))
        set("aspectx", Double(aspectX)); set("aspecty", Double(aspectY))
        set("zoom", p.number("zoom", 1)); set("zoomexp", p.number("fzoomexponent", 1)); set("rot", p.number("rot"))
        set("warp", p.number("warp", 1)); set("cx", p.number("cx", 0.5)); set("cy", p.number("cy", 0.5))
        set("dx", p.number("dx")); set("dy", p.number("dy")); set("sx", p.number("sx", 1)); set("sy", p.number("sy", 1))
        set("decay", p.number("fdecay", 0.98))
        set("wave_r", p.number("wave_r", 1)); set("wave_g", p.number("wave_g", 1)); set("wave_b", p.number("wave_b", 1))
        set("wave_a", p.number("fwavealpha", 1)); set("wave_x", p.number("wave_x", 0.5)); set("wave_y", p.number("wave_y", 0.5))
        set("wave_mystery", p.number("fwaveparam")); set("wave_mode", p.number("nwavemode"))
        set("wave_scale", p.number("fwavescale", 1))
        set("wave_usedots", p.number("bwavedots")); set("wave_thick", p.number("bwavethick"))
        set("wave_additive", p.number("badditivewaves")); set("wave_brighten", p.number("bmaximizewavecolor"))
        for key in ["ob_size", "ob_r", "ob_g", "ob_b", "ob_a", "ib_size", "ib_r", "ib_g", "ib_b", "ib_a"] { set(key, p.number(key)) }
        set("echo_zoom", p.number("fvideoechozoom", 1)); set("echo_alpha", p.number("fvideoechoalpha"))
        set("echo_orient", p.number("nvideoechoorientation")); set("gamma", p.number("fgammaadj", 1))
        set("wrap", p.number("btexwrap", 1)); set("darken_center", p.number("bdarkencenter"))
        set("invert", p.number("binvert")); set("brighten", p.number("bbrighten"))
        set("darken", p.number("bdarken")); set("solarize", p.number("bsolarize"))
        if !skipping.contains("perframe") { perFrame?.run() }

        // Mesh, then the picture over it.
        let meshCount = buildMesh(aspectX: aspectX, aspectY: aspectY, time: presetTime, measured: measured, into: meshBuffers[bufferIndex])
        var batches: [Batch] = []
        let drawCount = buildDrawing(audio: audio, time: presetTime, measured: measured, width: width, height: height,
                                     aspectX: aspectX, aspectY: aspectY, batches: &batches, into: drawBuffers[bufferIndex])

        let source = frames[current], destination = frames[1 - current]
        let wrapped = c["wrap"] > 0.0001
        let uniforms = shaderUniforms(width: width, height: height, aspectX: aspectX, aspectY: aspectY, time: presetTime,
                                      deltaTime: deltaTime, measured: measured)
        encode(buffer, destination, clear: false) { encoder in
            if let userWarp, let state = userWarp.pipeline(for: format) {
                encoder.setRenderPipelineState(state)
                encoder.setVertexBuffer(userMesh[bufferIndex], offset: 0, index: 0)
                userWarp.bind(encoder, uniforms: uniforms, textures: textures, main: source)
            } else {
                encoder.setRenderPipelineState(warpPipeline)
                encoder.setVertexBuffer(meshBuffers[bufferIndex], offset: 0, index: 0)
                encoder.setFragmentTexture(source, index: 0)
                encoder.setFragmentSamplerState(wrapped ? wrapSampler : clampSampler, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: meshCount)
        }
        encode(buffer, destination, clear: false, load: true) { encoder in
            encoder.setVertexBuffer(drawBuffers[bufferIndex], offset: 0, index: 0)
            for batch in batches where batch.count > 0 {
                encoder.setRenderPipelineState(batch.additive ? additivePipeline : alphaPipeline)
                encoder.drawPrimitives(type: .triangle, vertexStart: batch.start, vertexCount: batch.count)
            }
        }
        _ = drawCount

        var composite = Composite(echoZoom: Float(c["echo_zoom"]), echoAlpha: Float(c["echo_alpha"]),
                                  echoOrient: Float(c["echo_orient"]), gamma: Float(c["gamma"]),
                                  brighten: Float(c["brighten"]), darken: Float(c["darken"]),
                                  solarize: Float(c["solarize"]), invert: Float(c["invert"]))
        if composite.gamma <= 0 { composite.gamma = 1 }
        let quad = [(-1, 1, 0, 0), (1, 1, 1, 0), (-1, -1, 0, 1), (1, 1, 1, 0), (-1, -1, 0, 1), (1, -1, 1, 1)].map {
            Vertex(position: SIMD2(Float($0.0), Float($0.1)), uv: SIMD2(Float($0.2), Float($0.3)), color: SIMD4(1, 1, 1, 1))
        }
        encodeOutput(buffer, target) { encoder in
            if let userComposite, let state = userComposite.pipeline(for: target.pixelFormat) {
                encoder.setRenderPipelineState(state)
                encoder.setVertexBuffer(compMesh[bufferIndex], offset: 0, index: 0)
                userComposite.bind(encoder, uniforms: uniforms, textures: textures, main: destination)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: meshCount)
                return
            }
            guard let compositeState = compositePipeline(for: target.pixelFormat) else { return }
            encoder.setRenderPipelineState(compositeState)
            encoder.setVertexBytes(quad, length: quad.count * MemoryLayout<Vertex>.stride, index: 0)
            encoder.setFragmentTexture(destination, index: 0)
            encoder.setFragmentSamplerState(clampSampler, index: 0)
            encoder.setFragmentBytes(&composite, length: MemoryLayout<Composite>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        current = 1 - current
        bufferIndex = (bufferIndex + 1) % 3
        frameNumber += 1
    }

    private func compositePipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let cached = compositePipelines[format] { return cached }
        guard let function = library.makeFunction(name: "milk_composite") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = function
        descriptor.colorAttachments[0].pixelFormat = format
        let state = try? device.makeRenderPipelineState(descriptor: descriptor)
        compositePipelines[format] = state
        return state
    }

    private func makeFrames(width: Int, height: Int) {
        size = (width, height)
        frames = (0..<2).compactMap { _ in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        // Private textures start with whatever was in memory.
        guard let buffer = queue.makeCommandBuffer() else { return }
        for texture in frames { encode(buffer, texture, clear: true) { _ in } }
        buffer.commit()
        buffer.waitUntilCompleted()
        current = 0
    }

    private func encode(_ buffer: MTLCommandBuffer, _ texture: MTLTexture, clear: Bool, load: Bool = false,
                        _ body: (MTLRenderCommandEncoder) -> Void) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = clear ? .clear : (load ? .load : .dontCare)
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        body(encoder)
        encoder.endEncoding()
    }

    private func encodeOutput(_ buffer: MTLCommandBuffer, _ texture: MTLTexture, _ body: (MTLRenderCommandEncoder) -> Void) {
        encode(buffer, texture, clear: false, body)
    }

    // MARK: - The warp mesh

    /// Works out where every mesh point looks in last frame's picture, writing two triangles
    /// per cell. Returns how many vertices.
    private func buildMesh(aspectX: Float, aspectY: Float, time: Double, measured: LevelTracker.Levels,
                           into buffer: MTLBuffer) -> Int {
        let gx = Self.meshWidth, gy = Self.meshHeight
        let c = frameContext, px = pixelContext
        var uvs = [SIMD2<Float>](repeating: .zero, count: (gx + 1) * (gy + 1))
        var radAngs = uvs
        var decayColor = Float(min(c["decay"], 1))
        if decayColor < 0 { decayColor = 0 }

        let warpTime = Float(time * preset.number("fwarpanimspeed", 1))
        let warpScale = Float(preset.number("fwarpscale", 1))
        let warpScaleInverse = 1 / (warpScale == 0 ? 1 : warpScale)
        // Our own wobble for a preset's `warp` amount: two slow, drifting sine fields, one pushing
        // the picture sideways and one up and down, each from three waves of different spatial
        // frequency. (Presets get the same idea as MilkDrop's, not the same pattern.)
        let drift = SIMD3<Float>(warpTime * 0.29, warpTime * 0.47, warpTime * 0.71)
        let invAspectX = 1 / aspectX, invAspectY = 1 / aspectY

        // The per-frame values every point starts from.
        let base = Self.warpNames.map { c[$0] }
        let shared = Self.frameInputs.map { c[$0] }
        for (name, value) in zip(Self.frameInputs, shared) { px[name] = value }
        for i in 1...32 { px["q\(i)"] = c["q\(i)"] }
        let slots = Self.warpNames.map { px.slot($0)! }
        let xs = px.slot("x")!, ys = px.slot("y")!, rads = px.slot("rad")!, angs = px.slot("ang")!

        for j in 0...gy {
            for i in 0...gx {
                let x = Float(i) / Float(gx) * 2 - 1
                let y = Float(j) / Float(gy) * 2 - 1
                let radius = hypotf(x * aspectX, y * aspectY)
                let angle: Float = (j == gy / 2 && i == gx / 2) ? 0 : atan2f(y * aspectY, x * aspectX)
                radAngs[j * (gx + 1) + i] = SIMD2(radius, angle)
                var zoom = base[0], zoomExp = base[1], rot = base[2], warp = base[3], cx = base[4], cy = base[5]
                var dx = base[6], dy = base[7], sx = base[8], sy = base[9]
                if let perPixel, !skipping.contains("perpixel") {
                    px.values[xs] = Double(x * 0.5 * aspectX + 0.5)
                    px.values[ys] = Double(y * 0.5 * aspectY + 0.5)
                    px.values[rads] = Double(radius)
                    px.values[angs] = Double(-angle)
                    for (slot, value) in zip(slots, base) { px.values[slot] = value }
                    perPixel.run()
                    zoom = px.values[slots[0]]; zoomExp = px.values[slots[1]]; rot = px.values[slots[2]]; warp = px.values[slots[3]]
                    cx = px.values[slots[4]]; cy = px.values[slots[5]]; dx = px.values[slots[6]]; dy = px.values[slots[7]]
                    sx = px.values[slots[8]]; sy = px.values[slots[9]]
                }
                let z = Float(zoom), ze = Float(zoomExp)
                var zoom2 = powf(abs(z), powf(abs(ze), radius * 2 - 1))
                if !zoom2.isFinite || zoom2 < 1e-4 { zoom2 = 1 }
                let zoom2Inverse = 1 / zoom2
                var u = x * aspectX * 0.5 * zoom2Inverse + 0.5
                var v = y * aspectY * 0.5 * zoom2Inverse + 0.5
                let centerX = Float(cx), centerY = Float(cy)
                u = (u - centerX) / (sx == 0 ? 1 : Float(sx)) + centerX
                v = (v - centerY) / (sy == 0 ? 1 : Float(sy)) + centerY
                let w = Float(warp) * 0.0035
                let wx = warpScaleInverse * 9 * x, wy = warpScaleInverse * 9 * y
                u += w * (sinf(drift.x + wx * 1.1 - wy * 0.7) + 0.6 * sinf(drift.y - wx * 1.9 + wy * 1.3) + 0.4 * sinf(drift.z + wx * 2.6 + wy * 2.3))
                v += w * (cosf(drift.x * 1.3 + wx * 0.8 + wy * 1.2) + 0.6 * cosf(drift.y * 0.9 + wx * 1.7 - wy * 1.6) + 0.4 * cosf(drift.z * 1.1 - wx * 2.2 + wy * 2.8))
                let u2 = u - centerX, v2 = v - centerY
                let cosR = cosf(Float(rot)), sinR = sinf(Float(rot))
                u = u2 * cosR - v2 * sinR + centerX
                v = u2 * sinR + v2 * cosR + centerY
                u -= Float(dx)
                v -= Float(dy)
                u = (u - 0.5) * invAspectX + 0.5
                v = (v - 0.5) * invAspectY + 0.5
                uvs[j * (gx + 1) + i] = SIMD2(u, v)
            }
        }
        let out = buffer.contents().bindMemory(to: Vertex.self, capacity: gx * gy * 6)
        let color = SIMD4<Float>(decayColor, decayColor, decayColor, 1)
        func vertex(_ i: Int, _ j: Int) -> Vertex {
            // Mesh row 0 is the top of the picture.
            Vertex(position: SIMD2(Float(i) / Float(gx) * 2 - 1, 1 - Float(j) / Float(gy) * 2), uv: uvs[j * (gx + 1) + i], color: color)
        }
        var n = 0
        for j in 0..<gy {
            for i in 0..<gx {
                let a = vertex(i, j), b = vertex(i + 1, j), cc = vertex(i, j + 1), d = vertex(i + 1, j + 1)
                out[n] = a; out[n + 1] = b; out[n + 2] = cc
                out[n + 3] = b; out[n + 4] = cc; out[n + 5] = d
                n += 6
            }
        }
        // Shaders from the preset get the same mesh with more to read at each point.
        func fillUser(_ target: MTLBuffer, uv: (Int, Int) -> SIMD2<Float>, color: SIMD4<Float>) {
            let out = target.contents().bindMemory(to: UserVertex.self, capacity: gx * gy * 6)
            func point(_ i: Int, _ j: Int) -> UserVertex {
                UserVertex(position: SIMD2(Float(i) / Float(gx) * 2 - 1, 1 - Float(j) / Float(gy) * 2), uv: uv(i, j),
                           uvOrig: SIMD2(Float(i) / Float(gx), Float(j) / Float(gy)), radAng: radAngs[j * (gx + 1) + i], color: color)
            }
            var n = 0
            for j in 0..<gy {
                for i in 0..<gx {
                    let a = point(i, j), b = point(i + 1, j), cc = point(i, j + 1), d = point(i + 1, j + 1)
                    out[n] = a; out[n + 1] = b; out[n + 2] = cc
                    out[n + 3] = b; out[n + 4] = cc; out[n + 5] = d
                    n += 6
                }
            }
        }
        if userWarp != nil { fillUser(userMesh[bufferIndex], uv: { uvs[$1 * (gx + 1) + $0] }, color: color) }
        if userComposite != nil { fillUser(compMesh[bufferIndex], uv: { SIMD2(Float($0) / Float(gx), Float($1) / Float(gy)) }, color: SIMD4(1, 1, 1, 1)) }
        return n
    }

    /// The numbers a preset shader reads, by the names the shader language gives them.
    private func shaderUniforms(width: Int, height: Int, aspectX: Float, aspectY: Float, time: Double, deltaTime: Double,
                                measured: LevelTracker.Levels) -> [String: [Float]] {
        let t = Float(time)
        var u: [String: [Float]] = [:]
        u["rand_frame"] = (0..<4).map { _ in Float.random(in: 0..<1) }
        u["rand_preset"] = [randomPreset.x, randomPreset.y, randomPreset.z, randomPreset.w]
        u["_c0"] = [aspectX, aspectY, 1 / aspectX, 1 / aspectY]
        u["_c1"] = [0, 0, 0, 0]
        u["_c2"] = [t, Float(deltaTime > 0 ? 1 / deltaTime : 60), Float(frameNumber), 0]
        let vol = (measured.bass + measured.mid + measured.treb) / 3
        let volAtt = (measured.bassAtt + measured.midAtt + measured.trebAtt) / 3
        u["_c3"] = [measured.bass, measured.mid, measured.treb, vol]
        u["_c4"] = [measured.bassAtt, measured.midAtt, measured.trebAtt, volAtt]
        // Blur textures aren't made yet, so the picture stands in for them, unscaled.
        u["_c5"] = [1, 0, 1, 0]
        u["_c6"] = [1, 0, 0, 1]
        u["_c7"] = [Float(width), Float(height), 1 / Float(width), 1 / Float(height)]
        func wave(_ f: (Float) -> Float, _ speeds: [Float], _ phase: Float) -> [Float] { speeds.map { 0.5 + 0.5 * f(t * $0 + phase) } }
        u["_c8"] = wave(cosf, [0.329, 1.293, 5.1, 20.2], 1.2)
        u["_c9"] = wave(sinf, [0.329, 1.293, 5.1, 20.2], 1.2)
        u["_c10"] = wave(cosf, [0.005, 0.008, 0.013, 0.022], 2.7)
        u["_c11"] = wave(sinf, [0.005, 0.008, 0.013, 0.022], 2.7)
        u["_c12"] = [1, 1, 0.5, 0]
        u["_c13"] = [0, 1, 0, 1]
        let banks = ["_qa", "_qb", "_qc", "_qd", "_qe", "_qf", "_qg", "_qh"]
        for (i, name) in banks.enumerated() { u[name] = (1...4).map { Float(frameContext["q\(i * 4 + $0)"]) } }
        return u
    }

    // MARK: - Waves, shapes and borders

    private final class Drawing {
        var vertices: [Vertex] = []
        var batches: [Batch] = []
        let limit: Int
        init(limit: Int) { self.limit = limit }

        func add(_ new: [Vertex], additive: Bool) {
            guard !new.isEmpty, vertices.count + new.count <= limit else { return }
            if let last = batches.last, last.additive == additive {
                batches[batches.count - 1].count += new.count
            } else {
                batches.append(Batch(additive: additive, start: vertices.count, count: new.count))
            }
            vertices.append(contentsOf: new)
        }
    }

    private func buildDrawing(audio: MilkAudio, time: Double, measured: LevelTracker.Levels, width: Int, height: Int,
                              aspectX: Float, aspectY: Float, batches: inout [Batch], into buffer: MTLBuffer) -> Int {
        let drawing = Drawing(limit: Self.maxDrawVertices)
        let c = frameContext
        let unit = SIMD2<Float>(2 / Float(width), 2 / Float(height))

        if !skipping.contains("wave") { mainWave(drawing, audio: audio, unit: unit, aspectX: aspectX, aspectY: aspectY, width: width, vol: (measured.bass + measured.mid + measured.treb) / 3, treb: measured.treb, time: time) }
        for i in 0..<4 where preset.waves[i].enabled && !skipping.contains("customwaves") {
            customWave(i, drawing, audio: audio, time: time, measured: measured, unit: unit)
        }
        for i in 0..<4 where preset.shapes[i].enabled && !skipping.contains("shapes") {
            customShape(i, drawing, time: time, measured: measured, aspectY: aspectY, unit: unit)
        }
        if !skipping.contains("borders") {
            border(drawing, size: c["ob_size"], color: color(c, "ob"))
            border(drawing, size: c["ib_size"], color: color(c, "ib"), inset: c["ob_size"])
        }

        batches = drawing.batches
        let capacity = Self.maxDrawVertices
        drawing.vertices.withUnsafeBytes { raw in
            memcpy(buffer.contents(), raw.baseAddress!, min(raw.count, capacity * MemoryLayout<Vertex>.stride))
        }
        return drawing.vertices.count
    }

    private func color(_ c: MilkContext, _ prefix: String) -> SIMD4<Float> {
        SIMD4(Float(c["\(prefix)_r"]), Float(c["\(prefix)_g"]), Float(c["\(prefix)_b"]), Float(c["\(prefix)_a"]))
    }

    /// A frame around the picture, `size` of its width and height thick.
    private func border(_ drawing: Drawing, size: Double, color: SIMD4<Float>, inset: Double = 0) {
        guard size > 0, color.w > 0.0001 else { return }
        let outer = Float(1 - inset), inner = Float(1 - inset - size)
        func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> [Vertex] {
            [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x0, y1), SIMD2(x1, y0), SIMD2(x0, y1), SIMD2(x1, y1)]
                .map { Vertex(position: $0, uv: .zero, color: color) }
        }
        var v: [Vertex] = []
        v += quad(-outer, outer, outer, inner)
        v += quad(-outer, -inner, outer, -outer)
        v += quad(-outer, inner, -inner, -inner)
        v += quad(inner, inner, outer, -inner)
        drawing.add(v, additive: false)
    }

    /// MilkDrop's colour values wrap past 1, so a code line like `r = time` cycles through hues.
    private static func wrapped(_ x: Float) -> Float {
        guard x.isFinite else { return 0 }
        let clamped = max(-1e6, min(1e6, x * 255))
        return Float(Int(clamped) & 0xFF) / 255
    }

    private static func wrapped(_ c: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4(wrapped(c.x), wrapped(c.y), wrapped(c.z), wrapped(c.w))
    }

    /// The preset's own wave, in one of its nine shapes.
    private func mainWave(_ drawing: Drawing, audio: AudioView, unit: SIMD2<Float>, aspectX: Float, aspectY: Float, width: Int, vol: Float, treb: Float, time: Double) {
        let c = frameContext
        let mode = Int(c["wave_mode"].rounded())
        guard (0...8).contains(mode), !audio.waveform.isEmpty else { return }
        // Two channels of scope, -1...1 before the preset's scale: the left is the sound as it
        // is, the right a copy a little later, so the stereo shapes have something to open on.
        let n = 480
        let delay = n / 33
        var left = (0..<n).map { sampleWave(audio.waveform, Float($0) / Float(n - 1)) }
        let scale = Float(preset.number("fwavescale", 1))
        // Smoothing is a one-pole filter run along the scope.
        let hold = Float(min(max(preset.number("fwavesmoothing", 0.75), 0), 0.98))
        for i in 1..<n { left[i] = left[i] * (1 - hold) + left[i - 1] * hold }
        left = left.map { $0 * scale }
        let right = (0..<n).map { left[($0 + delay) % n] }
        let mystery = Float(c["wave_mystery"])
        let centre = SIMD2(2 * Float(c["wave_x"]) - 1, 2 * Float(c["wave_y"]) - 1)
        let time = Float(time)
        let fit = SIMD2(aspectY, aspectX)  // keeps round things round on a wide picture
        var lines: [[SIMD2<Float>]] = []
        var closed = false

        /// The line modes lay the scope along a line through the centre, tilted by `wave_mystery`
        /// and cut off where it leaves the picture. Returns the start, the step between samples
        /// and the direction the scope pushes the line.
        func straightLine(_ samples: Int, through middle: SIMD2<Float>) -> (start: SIMD2<Float>, step: SIMD2<Float>, push: SIMD2<Float>) {
            let tilt = mystery * Float.pi / 2
            let direction = SIMD2(cosf(tilt), sinf(tilt))
            // Clip the parameter range to the box -1.1...1.1 on both axes.
            var lower: Float = -4, upper: Float = 4
            for axis in 0..<2 where abs(direction[axis]) > 1e-5 {
                let a = (-1.1 - middle[axis]) / direction[axis], b = (1.1 - middle[axis]) / direction[axis]
                lower = max(lower, min(a, b))
                upper = min(upper, max(a, b))
            }
            if upper <= lower { lower = -1; upper = 1 }
            let start = middle + direction * lower, end = middle + direction * upper
            return (start, (end - start) / Float(samples), SIMD2(-direction.y, direction.x))
        }

        switch mode {
        case 0:
            // A ring around the centre. The scope runs out and back, so the ring closes with no seam.
            closed = true
            let points = n / 2
            lines = [(0..<points).map { i in
                let t = Float(i) / Float(points)
                let sample = right[Int(abs(2 * t - 1) * Float(n - 1))]
                let radius = 0.5 + 0.38 * sample + mystery
                let angle = t * 2 * Float.pi + time * 0.15
                return SIMD2(cosf(angle), sinf(angle)) * radius * fit + centre
            }]
        case 1:
            // A rose: three turns around the centre, the scope pushing the petals in and out.
            let points = n
            lines = [(0..<points).map { i in
                let t = Float(i) / Float(points - 1)
                let radius = 0.4 + 0.35 * left[i] + mystery * 0.5
                let angle = t * 6 * Float.pi + time * 0.5
                return SIMD2(cosf(angle), sinf(angle)) * radius * fit + centre
            }]
        case 2, 3:
            // The two channels against each other, like an oscilloscope in X-Y mode.
            lines = [(0..<n).map { i in SIMD2(left[i], right[i]) * fit + centre }]
        case 4:
            // A line across the picture that the scope pushes up and down, and sideways a little.
            let points = n / 2
            lines = [(0..<points).map { i in
                let t = Float(i) / Float(points - 1)
                return SIMD2(-1 + 2 * t + 0.3 * right[i], 0.45 * left[i]) + centre
            }]
        case 5:
            // The X-Y scope turned slowly, with each channel mixed into the other.
            let turn = time * 0.25
            let cosT = cosf(turn), sinT = sinf(turn)
            lines = [(0..<n).map { i in
                let x = left[i] * cosT - right[i] * sinT
                let y = left[i] * sinT + right[i] * cosT
                return SIMD2(x * abs(x) * 1.6, y) * fit + centre
            }]
        case 6:
            let points = n / 2
            let line = straightLine(points, through: centre)
            lines = [(0..<points).map { i in line.start + line.step * Float(i) + line.push * (0.25 * left[i]) }]
        case 7:
            // Two lines either side of the centre, one from each channel.
            let points = n / 2
            let line = straightLine(points, through: centre)
            let gap: Float = 0.12
            lines = [(0..<points).map { i in line.start + line.step * Float(i) + line.push * (gap + 0.25 * left[i]) },
                     (0..<points).map { i in line.start + line.step * Float(i) + line.push * (-gap + 0.25 * right[i]) }]
        default:
            // The analyzer's bars as a line, loudness on a log scale.
            let points = 240
            let line = straightLine(points, through: centre)
            let bars = audio.bars
            lines = [(0..<points).map { i in
                let bar = bars.isEmpty ? 0 : sampleWave(bars, Float(i) / Float(points - 1))
                return line.start + line.step * Float(i) + line.push * (0.35 * log10f(1 + 9 * bar) * scale)
            }]
        }

        // Alpha. The modes that draw over themselves a lot are turned down, more at big sizes,
        // where a line crosses fewer pixels; then by volume if the preset asks; then clamped.
        var alpha = Float(c["wave_a"])
        let sizeFactor = min(3, max(1, Float(max(width, Int(Float(width) * 3 / 4))) / 512))
        if mode == 2 || mode == 5 {
            alpha *= 0.1 * sizeFactor
        } else if mode == 3 {
            alpha *= 0.14 * sizeFactor * (0.5 + min(treb, 2))
        }
        if preset.number("bmodwavealphabyvolume") > 0.5 {
            let start = Float(preset.number("fmodwavealphastart", 0.75)), end = Float(preset.number("fmodwavealphaend", 0.95))
            alpha = Float(c["wave_a"]) * min(1, max(0, (vol - start) / max(end - start, 0.001)))
        }
        alpha = max(0, min(1, alpha))
        guard alpha > 0.001 else { return }
        var rgb = SIMD3<Float>(Float(c["wave_r"]), Float(c["wave_g"]), Float(c["wave_b"]))
        if c["wave_brighten"] > 0, let top = [rgb.x, rgb.y, rgb.z].max(), top > 0.01 { rgb /= top }
        let color = SIMD4<Float>(rgb.x, rgb.y, rgb.z, alpha)
        let dotsOrThick = c["wave_usedots"] > 0.5 || c["wave_thick"] > 0.5
        for line in lines where line.count >= 2 {
            let smoothed = smooth(line)
            if c["wave_usedots"] > 0.5 {
                drawing.add(dots(smoothed, colors: [SIMD4<Float>](repeating: color, count: smoothed.count), size: 2, unit: unit), additive: c["wave_additive"] > 0.5)
            } else {
                drawing.add(polyline(smoothed, colors: [SIMD4<Float>](repeating: color, count: smoothed.count), width: dotsOrThick ? 2 : 1,
                                     unit: unit, closed: closed), additive: c["wave_additive"] > 0.5)
            }
        }
    }

    /// Puts a point between each pair, on a gentle curve through the neighbours.
    private func smooth(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let n = points.count
        guard n >= 2 else { return points }
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(n * 2)
        for i in 0..<(n - 1) {
            let before = points[max(0, i - 1)], here = points[i], next = points[i + 1], after = points[min(n - 1, i + 2)]
            out.append(here)
            // The usual four-point rule for a point halfway between two: (-1, 9, 9, -1) / 16.
            out.append((here + next) * (9.0 / 16.0) - (before + after) * (1.0 / 16.0))
        }
        out.append(points[n - 1])
        return out
    }

    private func sampleWave(_ wave: [Float], _ t: Float) -> Float {
        let position = t * Float(wave.count - 1)
        let i = Int(position), f = position - Float(i)
        let a = wave[min(i, wave.count - 1)], b = wave[min(i + 1, wave.count - 1)]
        return a + (b - a) * f
    }

    /// A custom wave: every sample is a point the preset's code places and colours.
    private func customWave(_ index: Int, _ drawing: Drawing, audio: MilkAudio, time: Double, measured: LevelTracker.Levels, unit: SIMD2<Float>) {
        let wave = preset.waves[index]
        let ctx = waveContexts[index]
        let n = wave.numbers
        setInputs(ctx, time: time, measured: measured)
        for i in 1...32 { ctx["q\(i)"] = frameContext["q\(i)"] }
        waveFrame[index]?.run()
        let samples = min(512, max(0, Int(ctx["samples"])))
        guard samples >= 2 else { return }
        let spectrum = (n["bspectrum"] ?? 0) != 0
        let scaling = Float(n["scaling"] ?? 1) * Float(frameContext["wave_scale"])
        let hold = min(0.95, max(0, Float(n["smoothing"] ?? 0.5)) * 0.9), take = 1 - hold
        let source: [Float] = spectrum ? audio.bars : audio.waveform
        guard !source.isEmpty else { return }
        let mult = scaling * (spectrum ? 0.25 : 0.5)
        var data = [Float](repeating: 0, count: samples)
        for s in 0..<samples { data[s] = sampleWave(source, Float(s) / Float(samples - 1)) }
        var smoothed = data
        // Smoothed along the wave and back, so nothing lags to one side.
        for s in 1..<samples { smoothed[s] = data[s] * take + smoothed[s - 1] * hold }
        for s in stride(from: samples - 2, through: 0, by: -1) { smoothed[s] = smoothed[s] * take + smoothed[s + 1] * hold }

        var points: [SIMD2<Float>] = []
        var colors: [SIMD4<Float>] = []
        let rs = ctx.slot("r")!, gs = ctx.slot("g")!, bs = ctx.slot("b")!, a_s = ctx.slot("a")!
        let xs = ctx.slot("x")!, ys = ctx.slot("y")!, sampleSlot = ctx.slot("sample")!
        let v1 = ctx.slot("value1")!, v2 = ctx.slot("value2")!
        let baseColor = (ctx.values[rs], ctx.values[gs], ctx.values[bs], ctx.values[a_s])
        for s in 0..<samples {
            let t = Float(s) / Float(samples - 1)
            ctx.values[sampleSlot] = Double(t)
            ctx.values[v1] = Double(smoothed[s] * mult)
            ctx.values[v2] = Double(smoothed[s] * mult)
            ctx.values[xs] = Double(t)
            ctx.values[ys] = 0.5 + Double(smoothed[s] * mult)
            ctx.values[rs] = baseColor.0; ctx.values[gs] = baseColor.1; ctx.values[bs] = baseColor.2; ctx.values[a_s] = baseColor.3
            wavePoint[index]?.run()
            points.append(SIMD2(Float(ctx.values[xs]) * 2 - 1, Float(ctx.values[ys]) * 2 - 1))
            colors.append(Self.wrapped(SIMD4(Float(ctx.values[rs]), Float(ctx.values[gs]), Float(ctx.values[bs]), Float(ctx.values[a_s]))))
        }
        ctx.values[rs] = baseColor.0; ctx.values[gs] = baseColor.1; ctx.values[bs] = baseColor.2; ctx.values[a_s] = baseColor.3
        let additive = (n["badditive"] ?? 0) != 0
        if (n["busedots"] ?? 0) != 0 {
            drawing.add(dots(points, colors: colors, size: (n["bdrawthick"] ?? 0) != 0 ? 3 : 2, unit: unit), additive: additive)
        } else {
            drawing.add(polyline(points, colors: colors, width: (n["bdrawthick"] ?? 0) != 0 ? 2 : 1, unit: unit, closed: false), additive: additive)
        }
    }

    /// A custom shape, once for each of its instances.
    private func customShape(_ index: Int, _ drawing: Drawing, time: Double, measured: LevelTracker.Levels, aspectY: Float, unit: SIMD2<Float>) {
        let shape = preset.shapes[index]
        let ctx = shapeContexts[index]
        setInputs(ctx, time: time, measured: measured)
        for i in 1...32 { ctx["q\(i)"] = frameContext["q\(i)"] }
        let instances = min(1024, max(1, Int(shape.numbers["num_inst"] ?? 1)))
        ctx["num_inst"] = Double(instances)
        for instance in 0..<instances {
            ctx["instance"] = Double(instance)
            // Each instance starts from the shape's own settings.
            setShapeDefaultsKeepingCode(ctx, shape)
            shapeFrame[index]?.run()
            let sides = min(100, max(3, Int(ctx["sides"])))
            let center = SIMD2<Float>(Float(ctx["x"]) * 2 - 1, Float(ctx["y"]) * 2 - 1)
            let inner = Self.wrapped(SIMD4<Float>(Float(ctx["r"]), Float(ctx["g"]), Float(ctx["b"]), Float(ctx["a"])))
            let outer = Self.wrapped(SIMD4<Float>(Float(ctx["r2"]), Float(ctx["g2"]), Float(ctx["b2"]), Float(ctx["a2"])))
            let rad = Float(ctx["rad"]), ang = Float(ctx["ang"])
            var ring: [SIMD2<Float>] = []
            for i in 0..<sides {
                let a = Float(i) / Float(sides) * 2 * .pi + ang + .pi * 0.25
                ring.append(SIMD2(center.x + rad * cosf(a) * aspectY, center.y + rad * sinf(a)))
            }
            var v: [Vertex] = []
            for i in 0..<sides {
                let next = (i + 1) % sides
                v.append(Vertex(position: center, uv: .zero, color: inner))
                v.append(Vertex(position: ring[i], uv: .zero, color: outer))
                v.append(Vertex(position: ring[next], uv: .zero, color: outer))
            }
            drawing.add(v, additive: Int(ctx["additive"]) != 0)
            let border = Self.wrapped(SIMD4<Float>(Float(ctx["border_r"]), Float(ctx["border_g"]), Float(ctx["border_b"]), Float(ctx["border_a"])))
            if border.w > 0.0001 {
                let thick: Float = Int(ctx["thick"]) != 0 ? 2 : 1
                drawing.add(polyline(ring, colors: [SIMD4<Float>](repeating: border, count: ring.count), width: thick, unit: unit, closed: true),
                            additive: false)
            }
        }
    }

    /// Puts a shape's numbers back before each instance runs, but not the values its code keeps.
    private func setShapeDefaultsKeepingCode(_ c: MilkContext, _ shape: MilkPreset.Shape) {
        let keep = (1...8).map { "t\($0)" } + (1...32).map { "q\($0)" }
        let saved = keep.map { c[$0] }
        let instance = c["instance"], instances = c["num_inst"]
        setShapeDefaults(c, shape)
        for (name, value) in zip(keep, saved) { c[name] = value }
        c["instance"] = instance
        c["num_inst"] = instances
    }

    private func setInputs(_ c: MilkContext, time: Double, measured: LevelTracker.Levels) {
        c["time"] = time
        c["frame"] = Double(frameNumber)
        c["bass"] = Double(measured.bass); c["mid"] = Double(measured.mid); c["treb"] = Double(measured.treb)
        c["bass_att"] = Double(measured.bassAtt); c["mid_att"] = Double(measured.midAtt); c["treb_att"] = Double(measured.trebAtt)
    }

    // MARK: - Geometry helpers

    /// A line as a strip of quads, `width` screen pixels thick. `unit` is a pixel in clip space.
    private func polyline(_ points: [SIMD2<Float>], colors: [SIMD4<Float>], width: Float, unit: SIMD2<Float>, closed: Bool) -> [Vertex] {
        guard points.count >= 2 else { return [] }
        var out: [Vertex] = []
        let half = width * 0.5 + 0.25
        let segments = closed ? points.count : points.count - 1
        for i in 0..<segments {
            let a = points[i], b = points[(i + 1) % points.count]
            // Work in pixels so the line is as thick across as along.
            let pa = SIMD2(a.x / unit.x, a.y / unit.y), pb = SIMD2(b.x / unit.x, b.y / unit.y)
            let d = pb - pa
            let length = (d.x * d.x + d.y * d.y).squareRoot()
            guard length > 1e-4, length.isFinite else { continue }
            let normal = SIMD2(-d.y, d.x) / length * half
            func clip(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2(p.x * unit.x, p.y * unit.y) }
            let ca = colors[i], cb = colors[(i + 1) % points.count]
            let q = [clip(pa + normal), clip(pa - normal), clip(pb + normal), clip(pb - normal)]
            out += [Vertex(position: q[0], uv: .zero, color: ca), Vertex(position: q[1], uv: .zero, color: ca),
                    Vertex(position: q[2], uv: .zero, color: cb), Vertex(position: q[1], uv: .zero, color: ca),
                    Vertex(position: q[2], uv: .zero, color: cb), Vertex(position: q[3], uv: .zero, color: cb)]
        }
        return out
    }

    private func dots(_ points: [SIMD2<Float>], colors: [SIMD4<Float>], size: Float, unit: SIMD2<Float>) -> [Vertex] {
        var out: [Vertex] = []
        let hx = size * unit.x * 0.5, hy = size * unit.y * 0.5
        for (p, c) in zip(points, colors) {
            let q = [SIMD2(p.x - hx, p.y - hy), SIMD2(p.x + hx, p.y - hy), SIMD2(p.x - hx, p.y + hy), SIMD2(p.x + hx, p.y + hy)]
            out += [q[0], q[1], q[2], q[1], q[2], q[3]].map { Vertex(position: $0, uv: .zero, color: c) }
        }
        return out
    }
}

/// MilkDrop's three loudness readings: each band as a multiple of how loud the music has been
/// lately, so about 1 is ordinary and a beat is well over it, and a smoothed copy of each.
struct LevelTracker {
    struct Levels {
        var bass: Float = 1, mid: Float = 1, treb: Float = 1
        var bassAtt: Float = 1, midAtt: Float = 1, trebAtt: Float = 1
    }

    private var average: [Float] = [0, 0, 0]
    private var longAverage: [Float] = [0, 0, 0]
    private var frames = 0

    mutating func update(audio: MilkAudio, deltaTime: Double) -> Levels {
        let bars = audio.bars
        guard bars.count >= 3 else { return Levels() }
        let third = bars.count / 3
        let ranges = [0..<third, third..<(2 * third), (2 * third)..<bars.count]
        let now = ranges.map { range in bars[range].reduce(0, +) / Float(max(range.count, 1)) }
        let fps = Float(deltaTime > 0 ? min(120, 1 / deltaTime) : 60)
        // The first reading is what the music is like, so it counts as ordinary.
        if frames == 0 { average = now; longAverage = now }
        var levels = Levels()
        var relative = [Float](repeating: 1, count: 3), attenuated = [Float](repeating: 1, count: 3)
        for band in 0..<3 {
            let rate: Float = now[band] > average[band] ? 0.2 : 0.5
            let a = powf(1 - rate, 30 / fps)
            average[band] = average[band] * a + now[band] * (1 - a)
            let longRate: Float = frames < 50 ? 0.9 : 0.992
            let l = powf(longRate, 30 / fps)
            longAverage[band] = longAverage[band] * l + now[band] * (1 - l)
            if abs(longAverage[band]) > 0.001 {
                relative[band] = now[band] / longAverage[band]
                attenuated[band] = average[band] / longAverage[band]
            }
        }
        frames += 1
        levels.bass = relative[0]; levels.mid = relative[1]; levels.treb = relative[2]
        levels.bassAtt = attenuated[0]; levels.midAtt = attenuated[1]; levels.trebAtt = attenuated[2]
        return levels
    }
}
