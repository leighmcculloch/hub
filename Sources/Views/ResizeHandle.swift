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

    @State private var widthAtDragStart: Double?

    var body: some View {
        Rectangle()
            // Nearly transparent, but wide enough to be an easy drag target.
            .fill(Color.primary.opacity(0.001))
            .frame(width: 6)
            .overlay(Divider())
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = widthAtDragStart ?? width
                        if widthAtDragStart == nil { widthAtDragStart = width }
                        let proposed = base + direction * Double(value.translation.width)
                        width = min(max(proposed, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
    }
}
