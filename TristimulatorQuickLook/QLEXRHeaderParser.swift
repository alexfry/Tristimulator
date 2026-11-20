import Foundation

struct EXRChromaticities: Equatable {
    let rx, ry: Float
    let gx, gy: Float
    let bx, by: Float
    let wx, wy: Float
}

struct EXRHeaderInfo {
    var colorSpace: String?
    var chromaticities: EXRChromaticities?
}

// Reads only the binary EXR header — no full decode.
// EXR header format: magic(4) | version(4) | [name\0 | type\0 | size:u32le | data]... | \0
// Multi-part files have the same per-attribute structure; we scan all parts.
func parseEXRHeader(url: URL) -> EXRHeaderInfo {
    var info = EXRHeaderInfo()

    guard let handle = try? FileHandle(forReadingFrom: url) else { return info }
    defer { try? handle.close() }

    // Read enough to cover the header — EXR headers are typically < 4 KB.
    let headerBytes = (try? handle.read(upToCount: 16_384)) ?? Data()
    guard headerBytes.count >= 8,
          headerBytes[0] == 0x76,
          headerBytes[1] == 0x2F,
          headerBytes[2] == 0x31,
          headerBytes[3] == 0x01
    else { return info }

    var offset = 8

    while offset < headerBytes.count {
        guard let name = readCString(headerBytes, &offset) else { break }
        if name.isEmpty { break }

        guard let type = readCString(headerBytes, &offset) else { break }

        guard offset + 4 <= headerBytes.count else { break }
        let size = headerBytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
        offset += 4

        let dataStart = offset
        let dataEnd   = dataStart + Int(size)
        guard dataEnd <= headerBytes.count else { break }

        if name == "colorSpace" && type == "string" {
            let raw = String(data: headerBytes[dataStart..<dataEnd], encoding: .utf8) ?? ""
            info.colorSpace = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        } else if name == "chromaticities" && type == "chromaticities" && size == 32 {
            let f: (Int) -> Float = { i in
                let bits = headerBytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: dataStart + i * 4, as: UInt32.self) }
                return Float(bitPattern: bits.littleEndian)
            }
            info.chromaticities = EXRChromaticities(
                rx: f(0), ry: f(1),
                gx: f(2), gy: f(3),
                bx: f(4), by: f(5),
                wx: f(6), wy: f(7)
            )
        }

        offset = dataEnd

        if info.colorSpace != nil && info.chromaticities != nil { break }
    }

    return info
}

private func readCString(_ data: Data, _ offset: inout Int) -> String? {
    guard let end = data[offset...].firstIndex(of: 0) else { return nil }
    let s = String(data: data[offset..<end], encoding: .utf8)
    offset = end + 1
    return s
}
