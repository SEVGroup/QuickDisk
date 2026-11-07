import SwiftUI
import MetalKit
import QuartzCore

/// Runs the selected original Metal generator as a live scan backdrop.
struct DemFinalWaveView: NSViewRepresentable {
    var animation: ScanAnimation = .demFinal

    func makeCoordinator() -> Coordinator { Coordinator(animation: animation) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.015, green: 0.02, blue: 0.04, alpha: 1)
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.select(animation)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var animation: ScanAnimation
        private let startTime = CACurrentMediaTime()

        init(animation: ScanAnimation) {
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            queue = device?.makeCommandQueue()
            self.animation = animation
            super.init()
            pipeline = buildPipeline(for: animation)
        }

        func select(_ animation: ScanAnimation) {
            guard animation != self.animation else { return }
            self.animation = animation
            pipeline = buildPipeline(for: animation)
        }

        private func buildPipeline(for animation: ScanAnimation) -> MTLRenderPipelineState? {
            guard let device,
                  let sourceURL = Bundle.module.url(forResource: animation.shaderResource, withExtension: "metal"),
                  let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
                NSLog("QuickDisk could not load scan animation shader %@", animation.shaderResource)
                return nil
            }
            do {
                let library = try device.makeLibrary(source: source, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "vert")
                descriptor.fragmentFunction = library.makeFunction(name: animation.fragmentFunction)
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("QuickDisk could not compile scan animation shader: %@", error.localizedDescription)
                return nil
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipeline, let queue,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            let animationTime = CACurrentMediaTime() - startTime
            var uniforms = SIMD4<Float>(Float(drawable.texture.width), Float(drawable.texture.height),
                                        Float(animationTime), 0)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

enum ScanAnimation: String, CaseIterable, Identifiable {
    case demFinal = "demFinal"
    case veilCrossing = "veilCrossing"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .demFinal: "Цветные волны"
        case .veilCrossing: "Veil Crossing · чёрно-белая"
        }
    }
    var fragmentFunction: String {
        switch self {
        case .demFinal: "frag"
        case .veilCrossing: "frag"
        }
    }
    var shaderResource: String {
        switch self {
        case .demFinal: "visual"
        case .veilCrossing: "veil_crossing"
        }
    }
}
