import MetalKit
import SwiftUI

enum TVVisualizerPreset: String, CaseIterable, Identifiable {
    case mirroredStage, stainedGlass, neonBloom, mirrorTunnel, auroraWeave, obsidianIris

    var id: Self { self }
    var title: String {
        switch self {
        case .mirroredStage: "Mirrored Stage"
        case .stainedGlass: "Stained Glass"
        case .neonBloom: "Neon Bloom"
        case .mirrorTunnel: "Mirror Tunnel"
        case .auroraWeave: "Aurora Weave"
        case .obsidianIris: "Obsidian Iris"
        }
    }

    var shaderIndex: Float {
        switch self {
        case .mirroredStage: 0
        case .stainedGlass: 1
        case .neonBloom: 2
        case .mirrorTunnel: 3
        case .auroraWeave: 4
        case .obsidianIris: 5
        }
    }
}

struct TVKaleidoscopeSurface: UIViewRepresentable {
    let preset: TVVisualizerPreset
    let time: Double
    let levels: [Double]
    let moving: Bool
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = KaleidoscopeCanvas(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.autoResizeDrawable = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        context.coordinator.prepare(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let renderer = context.coordinator
        renderer.frame.z = Float(time)
        renderer.frame.w = preset.shaderIndex
        if reduceMotion {
            renderer.audio = .zero
        } else if moving {
            let target = SIMD4(Float(levels[0]), Float(levels[1]), Float(levels[2]), 0)
            renderer.audio += (target - renderer.audio) * 0.22
        }
        view.setNeedsDisplay()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var frame = SIMD4<Float>.zero
        var audio = SIMD4<Float>.zero
        private var resources: Resources?
        private var inFlight = false

        func prepare(_ view: MTKView) {
            guard let device = view.device else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak view] in
                let resources = Resources(device: device)
                DispatchQueue.main.async { [weak self, weak view] in
                    self?.resources = resources
                    view?.setNeedsDisplay()
                }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            guard !inFlight, let resources, let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable, let buffer = resources.queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            frame.x = Float(drawable.texture.width)
            frame.y = Float(drawable.texture.height)
            let submittedFrame = frame, submittedAudio = audio
            var uniforms = Uniforms(frame: submittedFrame, audio: submittedAudio)
            encoder.setRenderPipelineState(resources.pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(resources.photo, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            inFlight = true
            buffer.present(drawable)
            buffer.addCompletedHandler { [weak self, weak view] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight = false
                    // Catch up if a preset or paused frame changed during rendering.
                    if self.frame != submittedFrame || self.audio != submittedAudio { view?.setNeedsDisplay() }
                }
            }
            buffer.commit()
        }
    }
}

private struct Uniforms {
    var frame: SIMD4<Float>
    var audio: SIMD4<Float>
}

private final class KaleidoscopeCanvas: MTKView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(contentScaleFactor, 1440 / max(bounds.width, bounds.height))
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        if drawableSize != size { drawableSize = size }
    }
}

private struct Resources {
    let pipeline: MTLRenderPipelineState
    let queue: MTLCommandQueue
    let photo: MTLTexture?

    init?(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary(), let queue = device.makeCommandQueue() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "tvKaleidoscopeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "tvKaleidoscopeFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipeline = pipeline
        self.queue = queue
        if let url = Bundle.main.url(forResource: "mirrored-stage", withExtension: "jpg", subdirectory: "ToolDrive/Wallpapers") {
            photo = try? MTKTextureLoader(device: device).newTexture(URL: url, options: [.SRGB: false])
        } else {
            photo = nil
        }
    }
}
