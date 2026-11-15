import Foundation
import Metal

/// A preset's own warp or composite shader, converted offline to Metal source. It finds out
/// what the shader wants (textures, samplers, a block of uniforms) from Metal's reflection, so
/// the converter's numbering doesn't matter.
@MainActor
final class MilkUserShader {
    enum Kind { case warp, composite }

    private struct TextureSlot {
        var name: String
        var index: Int
        var is3D: Bool
    }

    private struct SamplerSlot {
        var name: String
        var index: Int
    }

    private let device: MTLDevice
    private let fragment: MTLFunction
    private let vertex: MTLFunction
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var envIndex: Int?
    private var envLength = 0
    private var members: [String: (offset: Int, type: MTLDataType)] = [:]
    private var textureSlots: [TextureSlot] = []
    private var samplerSlots: [SamplerSlot] = []
    /// The uniform names the shader reads.
    var uniformNames: [String] { Array(members.keys) }

    init?(device: MTLDevice, source: String, kind: Kind, vertex: MTLFunction, error: inout String) {
        guard let library = try? device.makeLibrary(source: source, options: nil), let fragment = library.makeFunction(name: "main0") else {
            error = "doesn't compile"
            return nil
        }
        self.device = device
        self.fragment = fragment
        self.vertex = vertex
        guard let reflection = Self.makePipeline(device: device, vertex: vertex, fragment: fragment, format: .rgba16Unorm).1 else {
            error = "doesn't make a pipeline"
            return nil
        }
        for binding in reflection.fragmentBindings {
            switch binding.type {
            case .buffer:
                if let buffer = binding as? MTLBufferBinding, let structure = buffer.bufferStructType {
                    envIndex = binding.index
                    envLength = buffer.bufferDataSize
                    for member in structure.members { members[member.name] = (member.offset, member.dataType) }
                }
            case .texture:
                if let texture = binding as? MTLTextureBinding {
                    textureSlots.append(TextureSlot(name: binding.name, index: binding.index, is3D: texture.textureType == .type3D))
                }
            case .sampler:
                samplerSlots.append(SamplerSlot(name: binding.name, index: binding.index))
            default:
                break
            }
        }
    }

    private static func makePipeline(device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction,
                                     format: MTLPixelFormat) -> (MTLRenderPipelineState?, MTLRenderPipelineReflection?) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = format
        guard let result = try? device.makeRenderPipelineState(descriptor: descriptor, options: [.bindingInfo]) else { return (nil, nil) }
        return (result.0, result.1)
    }

    func pipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let cached = pipelines[format] { return cached }
        let state = Self.makePipeline(device: device, vertex: vertex, fragment: fragment, format: format).0
        pipelines[format] = state
        return state
    }

    /// Everything the shader asks for, bound by name.
    func bind(_ encoder: MTLRenderCommandEncoder, uniforms: [String: [Float]], textures: MilkTextures, main: MTLTexture) {
        if let envIndex, envLength > 0 {
            var bytes = [UInt8](repeating: 0, count: envLength)
            for (name, member) in members {
                let values = uniforms[name] ?? Self.defaultValue(name: name, type: member.type, textures: textures)
                values.withUnsafeBytes { raw in
                    let count = min(raw.count, envLength - member.offset)
                    if count > 0 { bytes.withUnsafeMutableBytes { $0.baseAddress!.advanced(by: member.offset).copyMemory(from: raw.baseAddress!, byteCount: count) } }
                }
            }
            encoder.setFragmentBytes(bytes, length: envLength, index: envIndex)
        }
        for slot in textureSlots {
            encoder.setFragmentTexture(textures.texture(named: slot.name, is3D: slot.is3D, main: main), index: slot.index)
        }
        for slot in samplerSlots {
            encoder.setFragmentSamplerState(textures.sampler(named: slot.name), index: slot.index)
        }
    }

    /// Anything the engine doesn't set: the size of a texture, the identity for a rotation, else 0.
    private static func defaultValue(name: String, type: MTLDataType, textures: MilkTextures) -> [Float] {
        if name.hasPrefix("texsize_") {
            let size = textures.size(named: String(name.dropFirst(8)))
            return [size.x, size.y, 1 / size.x, 1 / size.y]
        }
        if type == .float3x4 || type == .float4x3 || type == .float4x4 {
            return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        }
        return [0, 0, 0, 0]
    }
}

/// The textures a preset shader can ask for by name: noise in a few sizes, and the picture itself.
@MainActor
final class MilkTextures {
    private let device: MTLDevice
    private let noise2D: MTLTexture
    private let noise3D: MTLTexture
    private let gray: MTLTexture
    private var samplers: [String: MTLSamplerState] = [:]

    init?(device: MTLDevice) {
        self.device = device
        func random(_ width: Int, _ height: Int, _ depth: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = depth > 1 ? .type3D : .type2D
            descriptor.pixelFormat = .rgba8Unorm
            descriptor.width = width
            descriptor.height = height
            descriptor.depth = depth
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            var bytes = [UInt8](repeating: 0, count: width * height * depth * 4)
            var generator = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
            if depth > 1 {
                texture.replace(region: MTLRegionMake3D(0, 0, 0, width, height, depth), mipmapLevel: 0, slice: 0, withBytes: bytes,
                                bytesPerRow: width * 4, bytesPerImage: width * height * 4)
            } else {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
            }
            return texture
        }
        guard let n2 = random(256, 256, 1), let n3 = random(32, 32, 32), let g = random(1, 1, 1) else { return nil }
        noise2D = n2
        noise3D = n3
        gray = g
    }

    private func isMainLike(_ name: String) -> Bool {
        name.contains("main") || name.contains("blur")
    }

    func texture(named name: String, is3D: Bool, main: MTLTexture) -> MTLTexture {
        if is3D { return noise3D }
        if isMainLike(name) { return main }
        // Noise of any quality, the random ones, and (as a stand-in) a picture file on disk.
        return noise2D
    }

    func size(named name: String) -> SIMD2<Float> {
        if name.contains("noise") || name.hasPrefix("rand") { return SIMD2(256, 256) }
        return SIMD2(1, 1)
    }

    /// Names carry how to read them: `fw` is filtered and wrapping, `pc` is point-sampled and clamped.
    func sampler(named name: String) -> MTLSamplerState {
        let lower = name.lowercased()
        let key = ["fw", "fc", "pw", "pc"].first { lower.contains("_\($0)_") } ?? "fw"
        if let cached = samplers[key] { return cached }
        let descriptor = MTLSamplerDescriptor()
        let point = key.hasPrefix("p")
        descriptor.minFilter = point ? .nearest : .linear
        descriptor.magFilter = point ? .nearest : .linear
        let address: MTLSamplerAddressMode = key.hasSuffix("c") ? .clampToEdge : .repeat
        descriptor.sAddressMode = address
        descriptor.tAddressMode = address
        descriptor.rAddressMode = address
        let state = device.makeSamplerState(descriptor: descriptor)!
        samplers[key] = state
        return state
    }
}
