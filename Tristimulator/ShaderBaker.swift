// Bakes the ACES 2 Metal shader + LUT textures for the QuickLook extension.
// The baked shader has peakNits-dependent constants replaced with ACES2Params
// uniform reads, so the QuickLook extension can adapt to EDR headroom at runtime.

import Foundation
import Metal

enum ShaderBaker {

    static let seedPeakNits: Double = 1000.0

    static let outputDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()           // Tristimulator/
        .deletingLastPathComponent()           // repo root
        .appendingPathComponent("TristimulatorQuickLook")
        .appendingPathComponent("BakedShader")

    static let inverseOutputDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()           // Tristimulator/
        .deletingLastPathComponent()           // repo root
        .appendingPathComponent("TristimulatorQuickLook")
        .appendingPathComponent("BakedShaderInverse")

    // The forward QuickLook shader bakes the ACES 2 SDR sRGB display transform. The inverse
    // shader undoes exactly that: it takes an sRGB-encoded SDR image (Rec.709 primaries,
    // piecewise sRGB EOTF, 100 nits) and recovers scene-linear ACES2065-1 (AP0). Because sRGB
    // SDR is a fixed 100-nit transform there are no peakNits-dependent constants to patch, so
    // the inverse shader is baked verbatim from OCIO with no ACES2Params dynamisation.
    static let inverseDisplayName = "sRGB - Display"
    static let inverseViewName    = "ACES 2.0 - SDR 100 nits (Rec.709)"
    static let inverseOutputSpace = "ACES2065-1"   // AP0 — exact inverse of the forward shader's input

    static func bake() {
        print("🍳 ShaderBaker: starting bake…")

        guard let configPath = Bundle.main.path(
            forResource: "OCIO/studio-config-v4.0.0_aces-v2.0_ocio-v2.5",
            ofType: "ocio"
        ) else {
            print("❌ ShaderBaker: bundled OCIO config not found")
            return
        }

        do {
            let config = try OCIOConfig(path: configPath)
            let processor = try OCIOProcessor.makeACES2FixedFunctionProcessor(
                config: config,
                peakNits: seedPeakNits
            )

            var shaderNS: NSString?
            var texNS: NSArray?
            try processor.getGPUShaderAndTextures(&shaderNS, texturesData: &texNS)

            guard let shaderCode = shaderNS as? String else {
                print("❌ ShaderBaker: no shader code generated")
                return
            }

            let textures = texNS as? [[String: Any]] ?? []
            print("   OCIO shader: \(shaderCode.components(separatedBy: .newlines).count) lines, \(textures.count) textures")

            let wrappedSource = generateWrapper(ocioCode: shaderCode, textures: textures)

            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            var textureEntries: [[String: Any]] = []
            for (i, tex) in textures.enumerated() {
                guard let data = tex["data"] as? Data,
                      let name = tex["name"] as? String,
                      let type = tex["type"] as? String else { continue }

                var channels = tex["channels"] as? Int ?? 3

                // Apply the same fix as OCIOGPUProcessor: OCIO over-reports
                // 3 channels for 1D LUTs that the shader samples as .r only.
                if type == "1D" && channels == 3 && !shaderSamplesRGB(textureName: name, shaderCode: shaderCode) {
                    print("   ⚠️  \(name): OCIO says 3ch but shader uses .r only — overriding to 1ch")
                    channels = 1
                }

                let width = tex["width"] as? Int
                let writeData: Data
                if type == "1D", let w = width, channels < (tex["channels"] as? Int ?? 3) {
                    let trimmedCount = w * channels * MemoryLayout<Float>.size
                    writeData = data.prefix(trimmedCount)
                } else {
                    writeData = data
                }

                let binName = "aces2_tex_\(i).bin"
                let binURL = outputDir.appendingPathComponent(binName)
                try writeData.write(to: binURL)
                print("   ✓ Wrote \(binName) (\(writeData.count) bytes)")

                var entry: [String: Any] = [
                    "name": name,
                    "type": type,
                    "file": binName,
                    "channels": channels,
                    "channelType": tex["channelType"] as? String ?? "RGB"
                ]
                if let w = width { entry["width"] = w }
                if let h = tex["height"] as? Int { entry["height"] = h }
                if let e = tex["edgeLength"] as? Int { entry["edgeLength"] = e }
                textureEntries.append(entry)
            }

            // Embed shader source in the manifest — Xcode's file-system sync
            // copies .json reliably but skips text files it identifies as source code.
            let manifest: [String: Any] = [
                "shader": wrappedSource,
                "textures": textureEntries
            ]
            let manifestData = try JSONSerialization.data(
                withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            let manifestURL = outputDir.appendingPathComponent("aces2_manifest.json")
            try manifestData.write(to: manifestURL)
            print("   ✓ Wrote aces2_manifest.json (shader + \(textureEntries.count) textures)")

            print("🍳 ShaderBaker: done! Add BakedShader/ to the TristimulatorQuickLook target resources.")

        } catch {
            print("❌ ShaderBaker: \(error)")
        }
    }

    // MARK: - Inverse sRGB display bake

    /// Bakes the *inverse* ACES 2 sRGB display transform: sRGB-encoded SDR → scene-linear AP0.
    /// Produces a standalone Metal shader + LUT manifest (BakedShaderInverse/) that another
    /// project can load without linking OCIO — the inverse counterpart to `bake()`.
    static func bakeInverse() {
        print("🍳 ShaderBaker: starting inverse sRGB bake…")

        guard let configPath = Bundle.main.path(
            forResource: "OCIO/studio-config-v4.0.0_aces-v2.0_ocio-v2.5",
            ofType: "ocio"
        ) else {
            print("❌ ShaderBaker: bundled OCIO config not found")
            return
        }

        do {
            let config = try OCIOConfig(path: configPath)
            let processor = try OCIOProcessor.makeInverseDisplayProcessor(
                config: config,
                sourceSpace: inverseOutputSpace,
                display: inverseDisplayName,
                view: inverseViewName
            )

            var shaderNS: NSString?
            var texNS: NSArray?
            try processor.getGPUShaderAndTextures(&shaderNS, texturesData: &texNS)

            guard let shaderCode = shaderNS as? String else {
                print("❌ ShaderBaker: no inverse shader code generated")
                return
            }

            let textures = texNS as? [[String: Any]] ?? []
            print("   OCIO inverse shader: \(shaderCode.components(separatedBy: .newlines).count) lines, \(textures.count) textures")

            let wrappedSource = generateInverseWrapper(ocioCode: shaderCode, textures: textures)

            try FileManager.default.createDirectory(at: inverseOutputDir, withIntermediateDirectories: true)

            let textureEntries = writeTextures(
                textures, shaderCode: shaderCode,
                to: inverseOutputDir, binPrefix: "aces2_inv_tex_")

            // Embed shader source in the manifest — Xcode's file-system sync copies .json
            // reliably but skips text files it identifies as source code.
            let manifest: [String: Any] = [
                "shader": wrappedSource,
                "textures": textureEntries
            ]
            let manifestData = try JSONSerialization.data(
                withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            let manifestURL = inverseOutputDir.appendingPathComponent("aces2_inverse_manifest.json")
            try manifestData.write(to: manifestURL)
            print("   ✓ Wrote aces2_inverse_manifest.json (shader + \(textureEntries.count) textures)")

            print("🍳 ShaderBaker: inverse done! Copy BakedShaderInverse/ into the consuming project's resources.")

        } catch {
            print("❌ ShaderBaker (inverse): \(error)")
        }
    }

    /// Writes each OCIO LUT texture to `dir` as a `.bin` and returns manifest entries.
    /// Shared by the forward and inverse bakes; mirrors the texture handling in `bake()`.
    private static func writeTextures(_ textures: [[String: Any]],
                                      shaderCode: String,
                                      to dir: URL,
                                      binPrefix: String) -> [[String: Any]] {
        var textureEntries: [[String: Any]] = []
        for (i, tex) in textures.enumerated() {
            guard let data = tex["data"] as? Data,
                  let name = tex["name"] as? String,
                  let type = tex["type"] as? String else { continue }

            var channels = tex["channels"] as? Int ?? 3

            // OCIO over-reports 3 channels for 1D LUTs the shader samples as .r only.
            if type == "1D" && channels == 3 && !shaderSamplesRGB(textureName: name, shaderCode: shaderCode) {
                print("   ⚠️  \(name): OCIO says 3ch but shader uses .r only — overriding to 1ch")
                channels = 1
            }

            let width = tex["width"] as? Int
            let writeData: Data
            if type == "1D", let w = width, channels < (tex["channels"] as? Int ?? 3) {
                let trimmedCount = w * channels * MemoryLayout<Float>.size
                writeData = data.prefix(trimmedCount)
            } else {
                writeData = data
            }

            let binName = "\(binPrefix)\(i).bin"
            let binURL = dir.appendingPathComponent(binName)
            do {
                try writeData.write(to: binURL)
                print("   ✓ Wrote \(binName) (\(writeData.count) bytes)")
            } catch {
                print("   ❌ Failed to write \(binName): \(error)")
                continue
            }

            var entry: [String: Any] = [
                "name": name,
                "type": type,
                "file": binName,
                "channels": channels,
                "channelType": tex["channelType"] as? String ?? "RGB"
            ]
            if let w = width { entry["width"] = w }
            if let h = tex["height"] as? Int { entry["height"] = h }
            if let e = tex["edgeLength"] as? Int { entry["edgeLength"] = e }
            textureEntries.append(entry)
        }
        return textureEntries
    }

    /// Wrap the (un-modified) OCIO inverse function in a compute kernel.
    /// Input texture holds sRGB-encoded SDR pixels; output receives scene-linear AP0.
    private static func generateInverseWrapper(ocioCode: String, textures: [[String: Any]]) -> String {
        let orderedNames = parseTextureOrder(from: ocioCode, textures: textures)

        var textureDecls = ""
        var funcParams = ""
        var texIdx = 2

        for info in orderedNames {
            let comma = ",\n                "
            let samplerKind = info.type == "1D" ? "nearestSampler" : "linearSampler"

            switch info.type {
            case "3D": textureDecls += "\(comma)texture3d<float, access::sample> \(info.name) [[texture(\(texIdx))]]"
            case "2D": textureDecls += "\(comma)texture2d<float, access::sample> \(info.name) [[texture(\(texIdx))]]"
            default:   textureDecls += "\(comma)texture1d<float, access::sample> \(info.name) [[texture(\(texIdx))]]"
            }

            funcParams += funcParams.isEmpty ? "" : ",\n                    "
            funcParams += "\(info.name),\n                    \(samplerKind)"
            texIdx += 1
        }

        let ocioCallArgs = funcParams.isEmpty
            ? "color"
            : "\(funcParams),\n                    color"

        return """
        #include <metal_stdlib>
        using namespace metal;

        // ── OCIO-generated INVERSE ACES 2 sRGB display transform ──────────────────
        //    sRGB-encoded SDR (Rec.709, 100 nits)  →  scene-linear ACES2065-1 (AP0)
        \(ocioCode)

        // ── Kernel wrapper ───────────────────────────────────────────────────────
        kernel void ocioInverseColorTransform(
                texture2d<float, access::read>  inputTexture  [[texture(0)]],
                texture2d<float, access::write> outputTexture [[texture(1)]]\(textureDecls),
                uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) { return; }

            constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
            constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

            float4 color = inputTexture.read(gid);

            // sRGB-encoded display → scene-linear AP0
            color = OCIOTransform(
                    \(ocioCallArgs)
            );

            outputTexture.write(color, gid);
        }
        """
    }

    // MARK: - Kernel wrapper generation

    private static func generateWrapper(ocioCode: String, textures: [[String: Any]]) -> String {
        // Determine texture order from the OCIO function signature
        let orderedNames = parseTextureOrder(from: ocioCode, textures: textures)

        var textureDecls = ""
        var funcParams = ""
        var texIdx = 2

        for info in orderedNames {
            let comma = ",\n                "
            let samplerKind = info.type == "1D" ? "nearestSampler" : "linearSampler"

            switch info.type {
            case "3D": textureDecls += "\(comma)texture3d<float, access::sample> \(info.name) [[texture(\(texIdx))]]"
            case "2D": textureDecls += "\(comma)texture2d<float, access::sample> \(info.name) [[texture(\(texIdx))]]"
            default:   textureDecls += "\(comma)texture1d<float, access::sample> \(info.name) [[texture(\(texIdx))]]"
            }

            funcParams += funcParams.isEmpty ? "" : ",\n                    "
            funcParams += "\(info.name),\n                    \(samplerKind)"
            texIdx += 1
        }

        let ocioCallArgs: String
        if funcParams.isEmpty {
            ocioCallArgs = "aces2,\n                    color"
        } else {
            ocioCallArgs = "aces2,\n                    \(funcParams),\n                    color"
        }

        // Replace baked constants with aces2 uniform reads
        let dynamicOcio = dynamiseOCIOCode(ocioCode)

        return """
        #include <metal_stdlib>
        using namespace metal;

        struct ACES2Params {
            float m_2;
            float s_2;
            float t_1;
            float g;
            float limit_J_max;
            float model_gamma_inv;
            float sat;
            float sat_thr;
            float compr;
            float chroma_compress_scale;
            float mid_J;
            float focus_dist;
            float lower_hull_gamma_inv;
        };

        // ── OCIO-generated ACES 2 FixedFunction (AP0 → linear P3-D65) ───────────
        //    Baked constants replaced with aces2.* uniform reads.
        \(dynamicOcio)

        // ── Kernel wrapper ───────────────────────────────────────────────────────
        kernel void ocioColorTransform(
                texture2d<float, access::read>  inputTexture  [[texture(0)]],
                texture2d<float, access::write> outputTexture [[texture(1)]]\(textureDecls),
                constant float&    exposure      [[buffer(0)]],
                constant float4&   channelMask   [[buffer(1)]],
                constant float&    peakNits      [[buffer(2)]],
                constant float3x3& inputMatrix   [[buffer(3)]],
                constant ACES2Params& aces2      [[buffer(4)]],
                uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) { return; }

            constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
            constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

            float4 color = inputTexture.read(gid);

            // Source → AP0
            color.rgb = inputMatrix * color.rgb;

            // Exposure in scene-linear
            color.rgb *= exp2(exposure);

            // Channel isolation
            if (channelMask.w > 0.5)
                color.rgb = float3(color.a);
            else if (channelMask.x + channelMask.y + channelMask.z < 3.0)
                color.rgb = float3(dot(color.rgb, channelMask.xyz));

            // Pre-clamp in AP1 gamut (matches OCIO Generate_output_transform)
            {
                const float3x3 AP0_to_AP1 = float3x3(
                    float3( 1.4514393161, -0.0765537734,  0.0083161484),
                    float3(-0.2365107469,  1.1762296998, -0.0060324498),
                    float3(-0.2149285693, -0.0996759264,  0.9977163014)
                );
                const float3x3 AP1_to_AP0 = float3x3(
                    float3(0.6954522414,  0.0447945634, -0.0055258826),
                    float3(0.1406786965,  0.8596711185,  0.0040252103),
                    float3(0.1638690622,  0.0955343182,  1.0015006723)
                );
                float r_hit = 128.0 + 768.0 * (log(peakNits / 100.0) / log(10000.0 / 100.0));
                float upperBound = 8.0 * r_hit;
                float3 ap1 = AP0_to_AP1 * color.rgb;
                ap1 = clamp(ap1, 0.0, upperBound);
                color.rgb = AP1_to_AP0 * ap1;
            }

            // ACES 2 Output Transform (AP0 → linear P3-D65, dynamic peakNits)
            color = OCIOTransform(
                    \(ocioCallArgs)
            );

            // Post-clamp to [0, peakNits/100]
            color.rgb = clamp(color.rgb, 0.0, peakNits / 100.0);

            outputTexture.write(color, gid);
        }
        """
    }

    // MARK: - Dynamic constant replacement

    private static func dynamiseOCIOCode(_ code: String) -> String {
        var s = code

        // Scalar replacements (order matters — longer literals first to avoid partial matches)
        let replacements: [(String, String)] = [
            ("4.6796021847256952", "aces2.s_2"),
            ("10.1729107",         "aces2.m_2"),
            ("283.249878",         "aces2.limit_J_max"),
            ("40.816883",          "aces2.mid_J"),
            ("1051.56519",         "aces2.focus_dist"),
            ("0.826446235",        "aces2.lower_hull_gamma_inv"),
            ("0.402999997",        "aces2.sat"),
            ("0.000500000024",     "aces2.sat_thr"),
            ("10.3199997",         "aces2.compr"),
        ]

        for (literal, uniform) in replacements {
            let before = s.components(separatedBy: literal).count - 1
            s = s.replacingOccurrences(of: literal, with: uniform)
            let after = s.components(separatedBy: uniform).count - 1
            if before == 0 {
                print("   ⚠️  dynamise: literal \(literal) not found in shader")
            } else {
                print("   ✓ \(literal) → \(uniform) (\(before)×)")
            }
        }

        // Fourier weights: OCIO bakes raw_weight * chroma_compress_scale.
        // Replace with raw constants * aces2.chroma_compress_scale.
        let rawCosWeights = "float3(11.34072, 16.46899, 7.88380)"
        let rawSinWeights = "float3(14.66441, -6.37224, 9.19364)"
        let rawOffset = "77.12896"

        let bakedCosWeights = "float3(28.177105004310604, 40.918782982468606, 19.588056175708772)"
        let bakedSinWeights = "float3(36.435131137728689, -15.832440585136412, 22.842479106426239)"
        let bakedOffset = "191.63428819274904"

        if s.contains(bakedCosWeights) {
            s = s.replacingOccurrences(of: bakedCosWeights, with: "\(rawCosWeights) * aces2.chroma_compress_scale")
            s = s.replacingOccurrences(of: bakedSinWeights, with: "\(rawSinWeights) * aces2.chroma_compress_scale")
            s = s.replacingOccurrences(of: bakedOffset, with: "\(rawOffset) * aces2.chroma_compress_scale")
            print("   ✓ Fourier weights factored with aces2.chroma_compress_scale")
        } else {
            print("   ⚠️  dynamise: baked Fourier cosine weights not found")
        }

        // Thread aces2 through the OCIO struct and function signatures.
        // The OCIO code wraps everything in `struct ocioOCIOTransform` with a constructor.
        // We add `constant ACES2Params& aces2` as a member + constructor param.
        s = addAces2ToOCIOStruct(s)

        return s
    }

    private static func addAces2ToOCIOStruct(_ code: String) -> String {
        var s = code

        // Add aces2 parameter to the struct constructor (first occurrence only —
        // replacingOccurrences would also hit the constructor *call* site)
        if let range = s.range(of: "ocioOCIOTransform(\n") {
            s = s.replacingCharacters(in: range, with: "ocioOCIOTransform(\n  constant ACES2Params& aces2\n  , ")
        }

        // Initialize aces2 reference in the member initializer list (C++ requires this for references)
        if let range = s.range(of: ")\n{\n  this->") {
            s = s.replacingCharacters(in: range, with: ")\n: aces2(aces2)\n{\n  this->")
        }

        // Add aces2 member declaration alongside the texture members
        if let range = s.range(of: "\n// Declaration of all textures\n") {
            let insertion = "\nconstant ACES2Params& aces2;\n// Declaration of all textures\n"
            s = s.replacingCharacters(in: range, with: insertion)
        }

        // Add aces2 to the free-standing OCIOTransform wrapper function
        s = s.replacingOccurrences(
            of: "float4 OCIOTransform(\n  texture1d<float>",
            with: "float4 OCIOTransform(\n  constant ACES2Params& aces2\n  , texture1d<float>"
        )

        // Add aces2 to the constructor call inside the wrapper
        s = s.replacingOccurrences(
            of: "return ocioOCIOTransform(\n    ",
            with: "return ocioOCIOTransform(\n    aces2\n    , "
        )

        // Update the kernel's call to OCIOTransform to pass aces2
        // This is handled in generateWrapper's ocioCallArgs — we prepend aces2
        s = s.replacingOccurrences(
            of: "  , float4 inPixel)",
            with: "  , float4 inPixel)"
        )

        return s
    }

    // MARK: - OCIO channel detection (mirrors OCIOGPUProcessor.shaderSamplesRGB)

    private static func shaderSamplesRGB(textureName: String, shaderCode: String) -> Bool {
        if shaderCode.contains("float3 \(textureName)_sample") { return true  }
        if shaderCode.contains("float \(textureName)_sample")  { return false }
        return shaderCode.contains("\(textureName).sample") &&
               shaderCode.range(of: "\(textureName)\\.sample[^)]+\\)\\.rgb",
                                   options: .regularExpression) != nil
    }

    // MARK: - Texture order parsing

    private struct TexInfo {
        let name: String
        let type: String
    }

    private static func parseTextureOrder(from shaderCode: String, textures: [[String: Any]]) -> [TexInfo] {
        var nameToType: [String: String] = [:]
        for tex in textures {
            if let name = tex["name"] as? String, let type = tex["type"] as? String {
                nameToType[name] = type
            }
        }

        var ordered: [TexInfo] = []
        let lines = shaderCode.components(separatedBy: .newlines)
        var inFunc = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("OCIOTransform(") || trimmed.contains("ocioOCIOTransform(") {
                inFunc = true
            }
            if inFunc {
                if trimmed.contains("texture1d<float>") || trimmed.contains("texture2d<float>") || trimmed.contains("texture3d<float>") {
                    let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    for (i, part) in parts.enumerated() {
                        if (part.contains("texture1d") || part.contains("texture2d") || part.contains("texture3d")),
                           i + 1 < parts.count {
                            let name = parts[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
                            if let type = nameToType[name], !ordered.contains(where: { $0.name == name }) {
                                ordered.append(TexInfo(name: name, type: type))
                            }
                        }
                    }
                }
                if trimmed.hasPrefix("}") { break }
            }
        }

        if ordered.count != textures.count {
            print("   ⚠️ Texture order parse: found \(ordered.count)/\(textures.count), using extraction order")
            return textures.compactMap { tex in
                guard let name = tex["name"] as? String, let type = tex["type"] as? String else { return nil }
                return TexInfo(name: name, type: type)
            }
        }
        return ordered
    }
}
