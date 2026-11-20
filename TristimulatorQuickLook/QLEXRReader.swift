import ImageIO
import CoreGraphics
import Metal

enum QLReaderError: LocalizedError {
    case cannotOpen
    case cannotDecode
    case cannotCreateTexture

    var errorDescription: String? {
        switch self {
        case .cannotOpen:           return "Cannot open EXR file"
        case .cannotDecode:         return "Cannot decode EXR image data"
        case .cannotCreateTexture:  return "Cannot create Metal texture"
        }
    }
}

struct QLSourceImage {
    let texture:    MTLTexture
    let headerInfo: EXRHeaderInfo
}

func loadEXR(url: URL, device: MTLDevice) throws -> QLSourceImage {
    let headerInfo = parseEXRHeader(url: url)

    let options: [CFString: Any] = [
        kCGImageSourceShouldCache: false,
        kCGImageSourceShouldAllowFloat: true
    ]
    guard let src  = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
          let cgImg = CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary)
    else { throw QLReaderError.cannotOpen }

    let w = cgImg.width
    let h = cgImg.height

    let texture = try upload(cgImg: cgImg, width: w, height: h, device: device)
    return QLSourceImage(texture: texture, headerInfo: headerInfo)
}

// MARK: - Upload helpers

private func upload(cgImg: CGImage, width: Int, height: Int, device: MTLDevice) throws -> MTLTexture {
    // Fast path: ImageIO preserved float16 — read bytes directly from the data provider.
    if cgImg.bitsPerComponent == 16,
       cgImg.bitsPerPixel == 64,
       let provider = cgImg.dataProvider,
       let data = provider.data {
        return try uploadRaw(data: data, width: width, height: height,
                             bytesPerRow: width * 8, pixelFormat: .rgba16Float, device: device)
    }

    // Fallback: draw into a float16 CGBitmapContext so we always get rgba16Float data.
    // This covers EXRs where ImageIO normalises to a different bit depth (e.g. 8-bit preview layer).
    guard let cs = CGColorSpace(name: CGColorSpace.linearSRGB) else { throw QLReaderError.cannotDecode }
    let bitmapInfo = CGBitmapInfo(rawValue:
        CGBitmapInfo.floatComponents.rawValue |
        CGImageAlphaInfo.premultipliedLast.rawValue |
        CGBitmapInfo.byteOrder16Little.rawValue
    )
    let bytesPerRow = width * 8
    guard let ctx = CGContext(data: nil,
                              width: width, height: height,
                              bitsPerComponent: 16,
                              bytesPerRow: bytesPerRow,
                              space: cs,
                              bitmapInfo: bitmapInfo.rawValue)
    else { throw QLReaderError.cannotDecode }

    ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let pixelData = ctx.data else { throw QLReaderError.cannotDecode }
    let dataRef = Data(bytes: pixelData, count: bytesPerRow * height) as CFData
    return try uploadRaw(data: dataRef, width: width, height: height,
                         bytesPerRow: bytesPerRow, pixelFormat: .rgba16Float, device: device)
}

private func uploadRaw(data: CFData,
                       width: Int, height: Int,
                       bytesPerRow: Int,
                       pixelFormat: MTLPixelFormat,
                       device: MTLDevice) throws -> MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
    desc.usage        = [.shaderRead, .shaderWrite]
    desc.storageMode  = .shared

    guard let tex = device.makeTexture(descriptor: desc) else {
        throw QLReaderError.cannotCreateTexture
    }

    CFDataGetBytePtr(data).map { bytes in
        tex.replace(region:       MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel:  0,
                    withBytes:    bytes,
                    bytesPerRow:  bytesPerRow)
    }
    return tex
}
