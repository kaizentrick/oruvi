// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import MetalKit
import SwiftUI

/// Draw the moving background in a single GPU pass without rebuilding SwiftUI's
/// view graph per frame. The stationary background remains a native MeshGradient.
struct AnimatedMesh: NSViewRepresentable {
    let resources: Resources
    let palette: [Double]
    let framesPerSecond: Int

    func makeCoordinator() -> Renderer { Renderer(resources: resources) }

    func makeNSView(context: Context) -> MeshView {
        let view = MeshView(frame: .zero, device: resources.device)
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.framebufferOnly = true
        view.isPaused = true
        context.coordinator.setPalette(palette)
        view.delegate = context.coordinator
        view.setFrameRate(framesPerSecond)
        return view
    }

    func updateNSView(_ view: MeshView, context: Context) {
        context.coordinator.setPalette(palette)
        view.setFrameRate(framesPerSecond)
    }

    static func dismantleNSView(_ view: MeshView, coordinator: Renderer) {
        view.setFrameRate(0)
        view.delegate = nil
    }

    final class MeshView: MTKView {
        private var frameRate = 0
        private var drawingTimer: Timer?

        func setFrameRate(_ value: Int) {
            guard frameRate != value else { return }
            frameRate = value
            updateDrawingTimer()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateDrawingTimer()
        }

        private func updateDrawingTimer() {
            drawingTimer?.invalidate()
            drawingTimer = nil
            guard window != nil, frameRate > 0 else { return }
            // Drive the requested cadence even when it does not divide the
            // display refresh rate. MetalKit otherwise rounds 24 fps down on 60 Hz.
            let timer = Timer(timeInterval: 1 / Double(frameRate), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.draw() }
            }
            timer.tolerance = 0.001
            drawingTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    final class Resources {
        static let shared = Resources()
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState

        private init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let library = try? device.makeLibrary(source: Self.shader, options: nil) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "meshVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "meshFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            self.device = device
            self.queue = queue
            self.pipeline = pipeline
        }

        private static let shader = """
        #include <metal_stdlib>
        using namespace metal;

        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex meshVertex(uint index [[vertex_id]]) {
            const float2 corners[] = {float2(-1., -1.), float2(3., -1.), float2(-1., 3.)};
            float2 corner = corners[index];
            return {float4(corner, 0., 1.), float2((corner.x + 1.) * 0.5, (1. - corner.y) * 0.5)};
        }

        float3 row(float x, float center, float3 left, float3 middle, float3 right) {
            if (x < center) return mix(left, middle, smoothstep(0., center, x));
            return mix(middle, right, smoothstep(center, 1., x));
        }

        fragment float4 meshFragment(Vertex input [[stage_in]], constant float4 *palette [[buffer(0)]],
                                     constant float4 &motion [[buffer(1)]]) {
            float x = input.uv.x, y = input.uv.y;
            float centerX = motion.y, centerY = motion.z;
            float middleY = x < centerX ? mix(motion.x, centerY, smoothstep(0., centerX, x))
                                       : mix(centerY, motion.w, smoothstep(centerX, 1., x));
            float3 top = row(x, 0.5, palette[0].rgb, palette[1].rgb, palette[0].rgb);
            float3 middle = row(x, centerX, palette[3].rgb, palette[2].rgb, palette[1].rgb);
            float3 bottom = row(x, 0.5, palette[0].rgb, palette[3].rgb, palette[0].rgb);
            float3 color = y < middleY ? mix(top, middle, smoothstep(0., middleY, y))
                                       : mix(middle, bottom, smoothstep(middleY, 1., y));
            return float4(color, 1.);
        }
        """
    }

    final class Renderer: NSObject, MTKViewDelegate {
        private let resources: Resources
        private let paletteLock = NSLock()
        private var palette: [SIMD4<Float>] = []

        init(resources: Resources) { self.resources = resources }

        func setPalette(_ values: [Double]) {
            let colors = stride(from: 0, to: 12, by: 3).map { index in
                let rgb = SIMD3(Float(values[index]), Float(values[index + 1]), Float(values[index + 2]))
                return SIMD4(rgb.x, rgb.y, rgb.z, 1)
            }
            paletteLock.withLock { palette = colors }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            let colors = paletteLock.withLock { palette }
            guard colors.count == 4, let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let buffer = resources.queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            var motion = MeshMotion().positions
            encoder.setRenderPipelineState(resources.pipeline)
            colors.withUnsafeBufferPointer {
                if let address = $0.baseAddress {
                    encoder.setFragmentBytes(address, length: $0.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
                }
            }
            encoder.setFragmentBytes(&motion, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
