//
//  AMFLookToggleState.swift
//  Tristimulator
//
//  Persistence helpers for the AMF Look Transforms toggles (per-look enable state and
//  the node-level master switch), so they are saved and restored with the rest of the
//  per-image OCIO settings in `OCIOPipelineSettings`.
//
//  Looks are matched by a stable key rather than by array position, so a saved state
//  still lines up after the AMF's look list changes: unknown saved keys are ignored and
//  looks that weren't in the saved state keep their defaults.
//

import Foundation

enum AMFLookToggleState {

    /// Stable persistence keys for `looks`, index-aligned with the array.
    ///
    /// Each look is identified by its transform ID, else its CLF file name, else its
    /// hash, else its description. Repeated identifiers get an occurrence suffix
    /// (`id`, `id#2`, `id#3`…) so duplicates stay distinct.
    static func keys(for looks: [AMFLookTransform]) -> [String] {
        var seen: [String: Int] = [:]
        return looks.enumerated().map { i, look in
            let base = baseKey(for: look) ?? "look[\(i)]"
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            return n == 1 ? base : "\(base)#\(n)"
        }
    }

    private static func baseKey(for look: AMFLookTransform) -> String? {
        let candidates: [String?] = [
            look.transformId.map { "id:\($0)" },
            look.clfFile.map { "clf:\($0)" },
            look.hashValue.map { "hash:\($0)" },
            look.description.map { "desc:\($0)" },
        ]
        for case let c? in candidates {
            let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasSuffix(":") { return trimmed }
        }
        return nil
    }

    /// Snapshot the per-look enable state as `[key: enabled]` for persistence.
    static func snapshot(keys: [String], enabled: [Bool]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for (k, e) in zip(keys, enabled) { out[k] = e }
        return out
    }

    /// Overlay `saved` states onto `defaults`.
    ///
    /// Only looks that Tristimulator can apply (`resolvable[i] == true`) take a saved
    /// value; unresolvable or already-baked looks keep their default (off). Keys in
    /// `saved` that no longer exist are ignored, and new looks keep their default.
    static func merge(defaults: [Bool], keys: [String], resolvable: [Bool],
                      saved: [String: Bool]?) -> [Bool] {
        guard let saved, !saved.isEmpty else { return defaults }
        return defaults.enumerated().map { i, def in
            guard i < keys.count, i < resolvable.count, resolvable[i],
                  let v = saved[keys[i]] else { return def }
            return v
        }
    }
}
