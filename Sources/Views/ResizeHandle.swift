import AppKit
import SwiftUI

/// A thin draggable divider that resizes an adjacent panel.
///
/// `direction` is `+1` when the panel being resized sits to the *left* of the
/// handle (dragging right grows it) and `-1` when it sits to the right.
struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let direction: Double
    /// Called once when the drag ends, so the caller can persist the width
    /// rather than writing storage on every frame of the drag.
    var onCommit: () -> Void = {}

    @State private var widthAtDragStart: Double?
    @State private var isHovering = false
    /// Tracks our own `NSCursor.push` so we never `pop` a cursor we didn't
    /// push — an unbalanced pop would clobber another view's cursor.
    @State private var didPushCursor = false

    /// Hovered or mid-drag: the divider thickens and tints so the handle is
    /// discoverable rather than looking like a plain separator.
    private var isActive: Bool { isHovering || widthAtDragStart != nil }

    /// How much a keyboard/VoiceOver adjustment moves the panel.
    private static let adjustmentStep: Double = 20

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            // A hairline is all the width the divider takes in the layout, so
            // the panels meet at one line instead of either side of a band of
            // window background.
            .frame(width: 1)
            .overlay {
                // Overlays aren't clipped to that hairline, so both of these
                // can be wider than it without moving the panels — widening
                // the frame instead would reflow the terminal on every hover.
                ZStack {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .opacity(isActive ? 1 : 0)
                    // Nearly transparent, but wide enough to be an easy drag
                    // target.
                    Color.primary.opacity(0.001)
                        .frame(width: 8)
                        .contentShape(Rectangle())
                }
            }
            .animation(.easeOut(duration: 0.12), value: isActive)
            .help("Drag to resize")
            .onHover { inside in
                isHovering = inside
                updateCursor()
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = widthAtDragStart ?? width
                        if widthAtDragStart == nil {
                            widthAtDragStart = width
                            // Keep the resize cursor while dragging past the handle.
                            updateCursor()
                        }
                        // Rounded to whole points: sub-pixel widths make the
                        // divider shimmer as the layout re-rounds each frame.
                        let proposed = (base + direction * Double(value.translation.width)).rounded()
                        if proposed != width { width = clamped(proposed) }
                    }
                    .onEnded { _ in
                        widthAtDragStart = nil
                        updateCursor()
                        onCommit()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Resize panel")
            .accessibilityValue(Text("\(Int(width)) points"))
            .accessibilityAdjustableAction { adjustment in
                switch adjustment {
                case .increment: width = clamped(width + Self.adjustmentStep)
                case .decrement: width = clamped(width - Self.adjustmentStep)
                @unknown default: break
                }
            }
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func updateCursor() {
        let wanted = isActive
        if wanted, !didPushCursor {
            NSCursor.resizeLeftRight.push()
            didPushCursor = true
        } else if !wanted, didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
    }
}
