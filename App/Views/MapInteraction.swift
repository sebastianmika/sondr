import AppKit
import SwiftUI

/// Catches the mouse, scroll wheel and trackpad gestures on the map, which SwiftUI gestures cannot.
/// Locations are in points, with y growing downwards.
struct MapInteractionView: NSViewRepresentable {
    var onMove: (CGPoint?) -> Void
    var onClick: (CGPoint) -> Void
    var onDoubleClick: () -> Void
    var onDrag: (CGPoint, CGPoint) -> Void
    var onDragEnd: (CGPoint, CGPoint) -> Void
    var onScroll: (CGSize, CGPoint, NSEvent.ModifierFlags) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onEscape: () -> Void
    var onOptionKey: (Bool) -> Void

    func makeNSView(context: Context) -> InteractionNSView {
        let view = InteractionNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: InteractionNSView, context: Context) { update(view) }

    private func update(_ view: InteractionNSView) {
        view.onMove = onMove
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onEscape = onEscape
        view.onOptionKey = onOptionKey
    }
}

final class InteractionNSView: NSView {
    var onMove: (CGPoint?) -> Void = { _ in }
    var onClick: (CGPoint) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onDrag: (CGPoint, CGPoint) -> Void = { _, _ in }
    var onDragEnd: (CGPoint, CGPoint) -> Void = { _, _ in }
    var onScroll: (CGSize, CGPoint, NSEvent.ModifierFlags) -> Void = { _, _, _ in }
    var onMagnify: (CGFloat, CGPoint) -> Void = { _, _ in }
    var onEscape: () -> Void = {}
    var onOptionKey: (Bool) -> Void = { _ in }

    private var dragStart: CGPoint?
    private var dragged = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) { onMove(location(event)) }
    override func mouseExited(with event: NSEvent) { onMove(nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            onDoubleClick()
            dragStart = nil
            return
        }
        dragStart = location(event)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = location(event)
        if dragged || hypot(now.x - start.x, now.y - start.y) > 4 {
            dragged = true
            onDrag(start, now)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        defer { dragStart = nil }
        let now = location(event)
        if dragged { onDragEnd(start, now) } else if event.clickCount == 1 { onClick(now) }
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), location(event), event.modifierFlags)
    }

    override func magnify(with event: NSEvent) { onMagnify(event.magnification, location(event)) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape() } else { super.keyDown(with: event) }
    }

    override func flagsChanged(with event: NSEvent) { onOptionKey(event.modifierFlags.contains(.option)) }
}
