import SwiftUI
import MetalKit
import QuartzCore

/// Runs the original DemFinal Metal shader as a live scan backdrop.
struct DemFinalWaveView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

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

    func updateNSView(_ view: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let queue: MTLCommandQueue?
        private let pipeline: MTLRenderPipelineState?
        private let startTime = CACurrentMediaTime()

        override init() {
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            queue = device?.makeCommandQueue()

            var builtPipeline: MTLRenderPipelineState?
            if let device,
               let sourceURL = Bundle.module.url(forResource: "visual", withExtension: "metal"),
               let source = try? String(contentsOf: sourceURL, encoding: .utf8) {
                do {
                    let library = try device.makeLibrary(source: source, options: nil)
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = library.makeFunction(name: "vert")
                    descriptor.fragmentFunction = library.makeFunction(name: "frag")
                    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                    builtPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                } catch {
                    NSLog("QuickDisk could not compile DemFinal wave shader: %@", error.localizedDescription)
                }
            } else {
                NSLog("QuickDisk could not load the DemFinal wave shader resource")
            }
            pipeline = builtPipeline
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipeline, let queue,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            var uniforms = SIMD4<Float>(Float(drawable.texture.width), Float(drawable.texture.height),
                                        Float(CACurrentMediaTime() - startTime), 0)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
