import MetalKit
import SwiftUI

@MainActor
struct TVTunnelSurface: UIViewRepresentable {
    let animating: Bool
    let player: AudioPlayer

    static var isAvailable: Bool { TVTunnelPipeline.shared != nil }

    func makeUIView(context: Context) -> TVTunnelView { TVTunnelView(pipeline: TVTunnelPipeline.shared) }

    func updateUIView(_ view: TVTunnelView, context: Context) {
        view.player = player
        view.animating = animating
    }

    static func dismantleUIView(_ view: TVTunnelView, coordinator: ()) {
        view.animating = false
        view.player = nil
        view.releaseDrawables()
    }
}

@MainActor
final class TVTunnelPipeline {
    static let shared = TVTunnelPipeline()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let state: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "tunnelVertex"),
              let fragment = library.makeFunction(name: "tunnelFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.state = state
    }
}

final class TVTunnelView: MTKView {
    weak var player: AudioPlayer? {
        didSet {
            if player !== oldValue, player != nil, isPaused { setNeedsDisplay() }
        }
    }
    var animating = false {
        didSet { if oldValue != animating { updateDrawingMode() } }
    }

    // Matches TunnelFrame in TVTunnel.metal, including float3's 16-byte alignment.
    private struct Frame {
        var size: SIMD2<Float>
        var phase: Float
        var padding: Float = 0
        var bands: SIMD3<Float>
    }

    private let pipeline: TVTunnelPipeline?
    private var seconds: TimeInterval = 0
    private var previousDraw: CFTimeInterval?
    private var envelope = SIMD3<Float>.zero
    private var pixelLimit: CGFloat = 1280
    private var sampleStart: CFTimeInterval?
    private var sampleFrames = 0

    init(pipeline: TVTunnelPipeline?) {
        self.pipeline = pipeline
        super.init(frame: .zero, device: pipeline?.device)
        colorPixelFormat = .bgra8Unorm
        isUserInteractionEnabled = false
        isOpaque = true
        framebufferOnly = true
        autoResizeDrawable = false
        preferredFramesPerSecond = 60
        isPaused = true
        enableSetNeedsDisplay = true
    }

    required init(coder: NSCoder) { fatalError("TVTunnelView is created in code.") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let longest = max(bounds.width, bounds.height)
        guard longest > 0 else { return }
        let scale = min(contentScaleFactor, pixelLimit / longest)
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        if drawableSize != size {
            drawableSize = size
            if isPaused { setNeedsDisplay() }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawingMode()
    }

    private func updateDrawingMode() {
        let running = animating && window != nil
        previousDraw = nil
        sampleStart = nil
        sampleFrames = 0
        isPaused = !running
        enableSetNeedsDisplay = !running
        if !running, window != nil { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard window != nil, player != nil, let pipeline,
              let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let command = pipeline.queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        if animating, let player {
            let now = CACurrentMediaTime()
            let dt = min(0.12, max(0, now - (previousDraw ?? now)))
            previousDraw = now
            seconds = (seconds + dt).truncatingRemainder(dividingBy: 48)
            let levels = player.visualizerLevels()
            for i in 0..<min(3, levels.count) {
                let level = Float(min(1, max(0, levels[i])))
                let decay = level > envelope[i] ? 0.055 : 0.18
                envelope[i] += (level - envelope[i]) * Float(1 - exp(-dt / decay))
            }
            tuneResolution(at: now)
        }
        var frame = Frame(size: SIMD2(Float(drawable.texture.width), Float(drawable.texture.height)),
                          phase: Float(seconds * .pi / 24), bands: envelope)
        encoder.setRenderPipelineState(pipeline.state)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private func tuneResolution(at now: CFTimeInterval) {
        guard pixelLimit > 640 else { return }
        guard let start = sampleStart else { sampleStart = now; return }
        sampleFrames += 1
        let interval = now - start
        guard interval >= 1.6 else { return }
        let target = min(preferredFramesPerSecond, window?.screen.maximumFramesPerSecond ?? 60)
        if Double(sampleFrames) / interval < 0.9 * Double(target) {
            pixelLimit = max(640, (max(drawableSize.width, drawableSize.height) * 0.8).rounded())
            setNeedsLayout()
        }
        sampleStart = now
        sampleFrames = 0
    }
}
