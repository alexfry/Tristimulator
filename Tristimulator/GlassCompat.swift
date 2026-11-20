//
//  GlassCompat.swift
//  Tristimulator
//
//  Backward-compatibility helpers so the app compiles and runs on macOS 15
//  (Sonoma) while preserving the Liquid Glass appearance on macOS 26 (Tahoe).
//

import SwiftUI

// MARK: - View helpers

extension View {

    /// Glass panel behind an overlay (diagrams, info bars, transport pills).
    /// On Tahoe: Liquid Glass with the given shape.
    /// On Sonoma: `.ultraThinMaterial` clipped to the same shape.
    @ViewBuilder
    func compatGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(in: shape)
        } else {
            self
                .background(shape.fill(.ultraThinMaterial))
                .clipShape(shape)
        }
    }

    /// Interactive glass card (pipeline node sections).
    /// On Tahoe: `.regular.interactive()` Liquid Glass.
    /// On Sonoma: `.ultraThinMaterial` with the same corner radius.
    @ViewBuilder
    func compatGlassInteractive<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self
                .background(shape.fill(.ultraThinMaterial))
                .clipShape(shape)
        }
    }

    /// Tinted glass toggle (segmented-control highlight).
    /// On Tahoe: tinted Liquid Glass when active, regular glass when inactive.
    /// Using `.regular` on both sides (not `.clear`) ensures both shapes
    /// contribute visible material so a surrounding `GlassEffectContainer`
    /// can morph them into a single segmented capsule.
    /// On Sonoma: accent-colored rounded-rect background when active, nothing
    ///            when inactive.
    @ViewBuilder
    func compatGlassToggle(isActive: Bool) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(isActive
                ? .regular.tint(.accentColor).interactive()
                : .regular.interactive())
        } else {
            self.background(
                isActive
                    ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                    : AnyShapeStyle(Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Tinted circle (channel indicator badge).
    /// On Tahoe: `.clear.tint(color)` Liquid Glass circle.
    /// On Sonoma: colored circle background.
    @ViewBuilder
    func compatGlassTintedCircle(tint: Color) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.clear.tint(tint), in: .circle)
        } else {
            self
                .background(Circle().fill(tint.opacity(0.3)))
                .clipShape(Circle())
        }
    }
}

// MARK: - Segmented control

/// A pill-shaped segmented picker with a single Liquid Glass capsule
/// background and a tinted thumb that slides to the selected segment via
/// `matchedGeometryEffect`. Mimics the look of Apple's native segmented
/// Liquid Glass controls. Falls back to `.ultraThinMaterial` on Sonoma.
struct GlassSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    let action: ((Value) -> Void)?

    @Namespace private var thumbNamespace

    init(selection: Binding<Value>,
         options: [(value: Value, label: String)],
         action: ((Value) -> Void)? = nil) {
        self._selection = selection
        self.options = options
        self.action = action
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let opt = options[i]
                Button {
                    selection = opt.value
                    action?(opt.value)
                } label: {
                    Text(opt.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(selection == opt.value ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background {
                    if selection == opt.value {
                        thumb
                            .matchedGeometryEffect(id: "thumb", in: thumbNamespace)
                    }
                }
            }
        }
        .padding(2)
        .compatGlass(in: Capsule())
        .animation(.snappy(duration: 0.22), value: selection)
    }

    /// Tinted Liquid Glass capsule on Tahoe, flat accent fill on Sonoma.
    @ViewBuilder
    private var thumb: some View {
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
        } else {
            Capsule().fill(Color.accentColor)
        }
    }
}

// MARK: - ToolbarContent helpers

extension ToolbarContent {

    /// Hides the shared glass background grouping on Tahoe; no-op on Sonoma.
    @ToolbarContentBuilder
    func compatHideSharedBackground() -> some ToolbarContent {
        if #available(macOS 26, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
