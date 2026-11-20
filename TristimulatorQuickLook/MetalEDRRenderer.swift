//
//  MetalEDRRenderer.swift
//  Tristimulator
//
//  Created by Alex Fry on 2/3/2026.
//

import Metal
import MetalKit
import simd

class MetalEDRRenderer {
    private let device: MTLDevice
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private var vertexBuffer: MTLBuffer?
    
    struct Vertex {
        var position: SIMD2<Float>
        var texCoord: SIMD2<Float>
    }
    
    struct Uniforms {
        var maxEDRHeadroom: Float
        var padding: SIMD3<Float>
    }
    
    init(device: MTLDevice) {
        self.device = device
        setupPipeline()
        setupBuffers()
        setupSampler()
    }
    
    private func setupPipeline() {
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "vertexShader")
        let fragmentFunction = library?.makeFunction(name: "fragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        
        // Enable blending for proper compositing
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
        
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create pipeline state: \(error)")
        }
    }
    
    private func setupBuffers() {
        // Full screen quad
        let vertices: [Vertex] = [
            Vertex(position: SIMD2(-1, -1), texCoord: SIMD2(0, 1)),
            Vertex(position: SIMD2(-1,  1), texCoord: SIMD2(0, 0)),
            Vertex(position: SIMD2( 1, -1), texCoord: SIMD2(1, 1)),
            Vertex(position: SIMD2( 1,  1), texCoord: SIMD2(1, 0))
        ]
        
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<Vertex>.stride * vertices.count,
            options: .storageModeShared
        )
    }
    
    private func setupSampler() {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: samplerDescriptor)
    }
    
    func render(
        texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor,
        drawable: CAMetalDrawable,
        useBlackBackground: Bool = false
    ) {
        guard let pipelineState = pipelineState,
              let vertexBuffer = vertexBuffer,
              let samplerState = samplerState else { return }

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        let grey: Double = useBlackBackground ? 0.0 : 0.1
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: grey, green: grey, blue: grey, alpha: 1.0)

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        let screen = NSScreen.main
        let maxEDRHeadroom = Float(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0)
        var uniforms = Uniforms(maxEDRHeadroom: maxEDRHeadroom, padding: SIMD3<Float>(0, 0, 0))

        renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        renderEncoder.setFragmentTexture(texture, index: 0)
        renderEncoder.setFragmentSamplerState(samplerState, index: 0)

        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
    }
}
