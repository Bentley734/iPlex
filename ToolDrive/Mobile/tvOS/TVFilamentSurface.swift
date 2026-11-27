import MetalKit
import SwiftUI

struct TVFilamentSurface: UIViewRepresentable {
    let preset: String
    let time: Double
    let levels: [Double]

    static var isAvailable: Bool { FilamentResources.library?.functionNames.contains("tdFilamentSections") == true }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = FilamentCanvas(frame: .zero, device: FilamentResources.device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.isUserInteractionEnabled = false
        view.backgroundColor = .black
        view.delegate = context.coordinator
        context.coordinator.prepare(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.preset = preset
        context.coordinator.time = time
        context.coordinator.levels = levels
        view.setNeedsDisplay()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var preset = "ember"
        var time = 0.0
        var levels: [Double] = []
        private var renderer: FilamentRenderer?

        func prepare(_ view: MTKView) {
            // Compile pipelines and accumulate the invariant flame material away
            // from both the Siri Remote event loop and the playback audio tap.
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak view] in
                let renderer = FilamentResources.shared.flatMap(FilamentRenderer.init)
                DispatchQueue.main.async { [weak self, weak view] in
                    self?.renderer = renderer
                    view?.setNeedsDisplay()
                }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer, let drawable = view.currentDrawable,
                  let buffer = renderer.resources.queue.makeCommandBuffer() else { return }
            renderer.encode(to: drawable.texture, buffer: buffer, preset: preset, time: time, levels: levels)
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

private final class FilamentCanvas: MTKView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(contentScaleFactor, 1280 / max(bounds.width, bounds.height))
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        if drawableSize != size { drawableSize = size }
    }
}

// Fixed layouts shared with TVFilament.metal. Precompute the cross-sections
// once per frame on the GPU, then use them for all latitudes and flame splats.
private struct FilamentPiece {
    var shape: SIMD4<UInt32> // preset, layer, arm, branch
    var mesh: SIMD4<UInt32>  // spine steps, thread count, rib stride, caustic count

    static func pieces(for preset: UInt32) -> [Self] {
        var pieces: [Self] = []
        func add(_ layer: UInt32, _ arm: UInt32, _ branch: UInt32, _ steps: UInt32,
                 _ threads: UInt32, ribs: UInt32 = 0, grains: UInt32 = 0) {
            pieces.append(Self(shape: SIMD4(preset, layer, arm, branch), mesh: SIMD4(steps, threads, ribs, grains)))
        }
        switch preset {
        case 0:
            for tier: UInt32 in 0..<3 {
                for arm: UInt32 in 0..<(tier == 1 ? 6 : 7) {
                    add(tier, arm, 0, tier == 0 ? 70 : 48, tier == 0 ? 31 : 18,
                        grains: tier == 0 ? 550 : (tier == 1 ? 190 : 0))
                    if tier < 2 { add(tier, arm, 1, 58, 9) }
                    if tier == 0 { add(tier, arm, 2, 58, 9) }
                }
            }
        case 1:
            for shell: UInt32 in [2, 1, 0] {
                add(shell, 0, 0, shell == 0 ? 176 : 110, shell == 0 ? 53 : 15,
                    ribs: shell == 0 ? 2 : 0, grains: shell == 0 ? 1350 : 0)
            }
            for arm: UInt32 in 0..<8 { add(0, arm, 1, 58, 9) }
        default:
            for facet: UInt32 in 0..<4 {
                add(facet, 0, 1, 64, 19)
                add(facet, 0, 0, 64, 49, ribs: 4, grains: 750)
            }
        }
        return pieces
    }
}

private struct FilamentLayout {
    let pieces: [FilamentPiece]
    let buffer: MTLBuffer
}

private struct FilamentNoise {
    var seed: UInt32
    mutating func next() -> Double {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Double(seed) / 4_294_967_296.0
    }
}

private enum FilamentMaterial {
    static func caustics() -> [SIMD4<Float>] {
        var random = FilamentNoise(seed: 78191)
        return (0..<1350).map { _ in
            let u = random.next(), side = random.next() < 0.5 ? -1.0 : 1.0
            let s = side * (0.85 + 0.45 * random.next() + pow(random.next(), 8) * 1.36)
            let grain = 0.0012 + 0.0028 * pow(random.next(), 4)
            return SIMD4(Float(u), Float(s), Float(grain), 0)
        }
    }

    static func dust() -> [SIMD4<Float>] {
        var random = FilamentNoise(seed: 246763)
        return (0..<480).map { _ in
            let x = 2 * random.next() - 1, y = 2 * random.next() - 1
            let size = 0.00135 + pow(random.next(), 5) * 0.0034
            let alpha = 0.055 + 0.17 * random.next()
            return SIMD4(Float(x), Float(y), Float(size), Float(alpha))
        }
    }

    // Same iterated function system and axial sampling order as the desktop
    // renderer. All three presets share its density map and supply their own ink.
    static func flame() -> [SIMD4<Float>] {
        let width = 520, height = 184
        var hits = [UInt32](repeating: 0, count: width * height)
        var hue = [Float](repeating: 0, count: hits.count)
        var x = 0.0, y = 0.0, tint = 0.5, random = FilamentNoise(seed: 468921)
        for index in 0..<230_000 {
            let p = random.next()
            let nx: Double, ny: Double, target: Double
            if p < 0.785 {
                nx = 0.831*x + 0.071*y; ny = -0.053*x + 0.843*y + 1.48; target = 0.66
            } else if p < 0.89 {
                nx = 0.24*x - 0.29*y; ny = 0.27*x + 0.24*y + 1.18; target = 0.21
            } else if p < 0.99 {
                nx = -0.19*x + 0.315*y; ny = 0.24*x + 0.22*y + 0.55; target = 0.91
            } else {
                nx = 0.041*x; ny = 0.17*y; target = 0.35
            }
            let angle = 0.061*sin(ny*0.84) + 0.039*sin(nx*1.65)
            x = nx*cos(angle) - ny*sin(angle)
            y = nx*sin(angle) + ny*cos(angle)
            tint = 0.61*tint + 0.39*target
            guard index >= 32 else { continue }
            let axial = y/10.05, transverse = x*0.278 - 0.115*axial, curl = sin(.pi*axial)
            let u = 0.018 + 0.955*axial + 0.12*curl*sin(transverse*4.1 + axial*6.1)
            let v = 0.103 + 0.79*(0.50 + 0.46*transverse + 0.14*curl*sin(8*axial + 3.2*transverse))
            let col = Int(floor(u*Double(width))), row = Int(floor(v*Double(height)))
            guard col >= 0, col < width, row >= 0, row < height else { continue }
            let cell = row*width + col
            hits[cell] += 1
            hue[cell] += Float(tint)
        }
        var material: [SIMD4<Float>] = []
        for col in 0..<width {
            for row in 0..<height {
                let i = row*width + col
                guard hits[i] > 0 else { continue }
                let heat = min(1, log1p(Double(hits[i]))*0.21)
                let shade = 1.12*(Double(hue[i])/Double(hits[i]) - 0.26) + 0.24*heat + 0.21*sin(5.6*Double(col)/Double(width))
                material.append(SIMD4((Float(col)+0.5)/Float(width), (Float(row)+0.5)/Float(height)*2 - 1,
                                      Float(heat), Float(max(0, min(1, shade)))))
            }
        }
        return material
    }
}

private final class FilamentResources {
    static let device = MTLCreateSystemDefaultDevice()
    static let library = device?.makeDefaultLibrary()
    static let shared = FilamentResources()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let sections: MTLComputePipelineState
    let backdrop, ribbon, caustics, flame, dust, bloom: MTLRenderPipelineState
    let causticSeeds, dustSeeds, flameSamples: MTLBuffer
    let flameCount: Int
    let layouts: [FilamentLayout]

    private init?() {
        guard let device = Self.device, let library = Self.library, let queue = device.makeCommandQueue(),
              let calculate = library.makeFunction(name: "tdFilamentSections") else { return nil }
        self.device = device
        self.queue = queue
        func pipeline(_ vertex: String, _ fragment: String, additive: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "tdFilament" + vertex)
            descriptor.fragmentFunction = library.makeFunction(name: "tdFilament" + fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            if additive {
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .one
                color.sourceAlphaBlendFactor = .zero
                color.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        func upload<T>(_ values: [T]) -> MTLBuffer? {
            values.withUnsafeBytes { bytes in
                guard let pointer = bytes.baseAddress else { return nil }
                return device.makeBuffer(bytes: pointer, length: bytes.count, options: .storageModeShared)
            }
        }
        do {
            sections = try device.makeComputePipelineState(function: calculate)
            backdrop = try pipeline("Screen", "Backdrop")
            ribbon = try pipeline("Ribbon", "Color", additive: true)
            caustics = try pipeline("Caustics", "Point", additive: true)
            flame = try pipeline("Flame", "Splat", additive: true)
            dust = try pipeline("Dust", "Point", additive: true)
            bloom = try pipeline("Screen", "Bloom")
        } catch {
            NSLog("Filament renderer could not create Metal pipelines: %@", error.localizedDescription)
            return nil
        }
        let material = FilamentMaterial.flame()
        guard let causticSeeds = upload(FilamentMaterial.caustics()), let dustSeeds = upload(FilamentMaterial.dust()),
              let flameSamples = upload(material) else { return nil }
        self.causticSeeds = causticSeeds
        self.dustSeeds = dustSeeds
        self.flameSamples = flameSamples
        flameCount = material.count
        var layouts: [FilamentLayout] = []
        for id: UInt32 in 0..<3 {
            let pieces = FilamentPiece.pieces(for: id)
            guard let buffer = upload(pieces) else { return nil }
            layouts.append(FilamentLayout(pieces: pieces, buffer: buffer))
        }
        self.layouts = layouts
    }
}

private final class FilamentRenderer {
    let resources: FilamentResources
    private let rows: MTLBuffer
    private var scene: MTLTexture?

    init?(_ resources: FilamentResources) {
        let maxPieces = resources.layouts.map { $0.pieces.count }.max() ?? 0
        // 180 sections per piece, each holding three float2 vectors.
        guard let rows = resources.device.makeBuffer(length: maxPieces * 180 * 24, options: .storageModePrivate) else { return nil }
        self.rows = rows
        self.resources = resources
    }

    func encode(to target: MTLTexture, buffer: MTLCommandBuffer, preset: String, time: Double, levels: [Double]) {
        let width = target.width, height = target.height
        if scene?.width != width || scene?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                      width: width, height: height, mipmapped: true)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            scene = resources.device.makeTexture(descriptor: descriptor)
        }
        guard let scene else { return }
        let id = preset == "tidal" ? 1 : (preset == "prism" ? 2 : 0)
        let layout = resources.layouts[id]
        func band(_ index: Int) -> Float {
            guard levels.indices.contains(index), levels[index].isFinite else { return 0 }
            return Float(max(0, min(1, levels[index])))
        }
        let display = SIMD4(Float(width), Float(height), Float(time.isFinite ? time : 0), Float(id))
        let audio = SIMD4(band(0), band(1), band(2), min(Float(width)/2.85, Float(height)/1.99))
        var frame = (display, audio)
        let frameBytes = MemoryLayout.size(ofValue: frame)
        guard let compute = buffer.makeComputeCommandEncoder() else { return }
        compute.setComputePipelineState(resources.sections)
        compute.setBytes(&frame, length: frameBytes, index: 0)
        compute.setBuffer(layout.buffer, offset: 0, index: 1)
        compute.setBuffer(rows, offset: 0, index: 2)
        // Uniform dispatch is supported on all Metal-capable Apple TV models.
        compute.dispatchThreadgroups(MTLSize(width: 6, height: layout.pieces.count, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        compute.endEncoding()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scene
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let render = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        render.setFragmentBytes(&frame, length: frameBytes, index: 0)
        render.setVertexBytes(&frame, length: frameBytes, index: 0)
        render.setVertexBuffer(layout.buffer, offset: 0, index: 1)
        render.setVertexBuffer(rows, offset: 0, index: 2)
        render.setRenderPipelineState(resources.backdrop)
        render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        render.setRenderPipelineState(resources.dust)
        render.setVertexBuffer(resources.dustSeeds, offset: 0, index: 4)
        render.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 480)
        for (index, piece) in layout.pieces.enumerated() {
            var draw = SIMD2(UInt32(index), UInt32(0))
            let steps = Int(piece.mesh.x), vertices = (steps + 1) * 2
            render.setRenderPipelineState(resources.ribbon)
            render.setVertexBytes(&draw, length: 8, index: 3)
            render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices)
            draw.y = 1
            render.setVertexBytes(&draw, length: 8, index: 3)
            render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices, instanceCount: Int(piece.mesh.y))
            if piece.mesh.z > 0 {
                draw.y = 2
                render.setVertexBytes(&draw, length: 8, index: 3)
                let ribs = (steps - 3) / Int(piece.mesh.z) + 1
                render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 18, instanceCount: ribs)
            }
            if piece.mesh.w > 0 {
                render.setRenderPipelineState(resources.caustics)
                render.setVertexBuffer(resources.causticSeeds, offset: 0, index: 4)
                render.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Int(piece.mesh.w))
            }
            drawFlame(on: render, piece: piece, mid: audio.y, high: audio.z)
        }
        render.endEncoding()
        if let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: scene)
            blit.endEncoding()
        }
        pass.colorAttachments[0].texture = target
        guard let composite = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        composite.setRenderPipelineState(resources.bloom)
        composite.setFragmentTexture(scene, index: 0)
        composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        composite.endEncoding()
    }

    private func drawFlame(on encoder: MTLRenderCommandEncoder, piece: FilamentPiece, mid: Float, high: Float) {
        func patch(_ start: Float, _ end: Float, _ spread: Float, _ light: Float) {
            encoder.setRenderPipelineState(resources.flame)
            encoder.setVertexBuffer(resources.flameSamples, offset: 0, index: 4)
            var values = SIMD4(start, end, spread, light)
            encoder.setVertexBytes(&values, length: 16, index: 5)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: resources.flameCount)
        }
        let layer = piece.shape.y, branch = piece.shape.w
        switch piece.shape.x {
        case 0:
            if layer == 0 && branch == 0 { patch(0.18, 0.84, -2.40, 0.56 + 0.10*high) }
        case 1:
            if layer == 0 && branch == 0 {
                patch(0.18, 0.62, 2.50, 0.73 + 0.10*mid)
                patch(0.51, 0.91, -2.40, 0.76 + 0.10*high)
                patch(0.72, 1, 2.16, 0.58)
            }
        default:
            let hand: Float = layer.isMultiple(of: 2) ? -1 : 1
            if branch == 0 { patch(0, 1, 2.20*hand, 0.70 + 0.12*high) }
            else { patch(0.33, 0.92, -1.95*hand, 0.42) }
        }
    }
}
