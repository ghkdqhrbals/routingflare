import AppKit

@MainActor
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()

            let cloud = NSBezierPath()
            cloud.lineWidth = 1.7
            cloud.lineCapStyle = .round
            cloud.lineJoinStyle = .round
            cloud.move(to: NSPoint(x: 5.1, y: 4.7))
            cloud.curve(to: NSPoint(x: 5.4, y: 12.4), controlPoint1: NSPoint(x: 0.4, y: 5.1), controlPoint2: NSPoint(x: 1.4, y: 11.9))
            cloud.curve(to: NSPoint(x: 14.7, y: 12.4), controlPoint1: NSPoint(x: 6.9, y: 17.8), controlPoint2: NSPoint(x: 13.2, y: 17.8))
            cloud.curve(to: NSPoint(x: 14.5, y: 4.7), controlPoint1: NSPoint(x: 18.7, y: 12.0), controlPoint2: NSPoint(x: 19.4, y: 5.2))
            cloud.line(to: NSPoint(x: 5.1, y: 4.7))
            cloud.stroke()

            let arrow = NSBezierPath()
            arrow.lineWidth = 1.7
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.move(to: NSPoint(x: 7.4, y: 7.1))
            arrow.line(to: NSPoint(x: 12.5, y: 12.2))
            arrow.move(to: NSPoint(x: 9.3, y: 12.2))
            arrow.line(to: NSPoint(x: 12.5, y: 12.2))
            arrow.line(to: NSPoint(x: 12.5, y: 9.0))
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
