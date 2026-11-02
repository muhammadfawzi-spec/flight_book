// LogMate branding: the app name, the prototype-only flight reset toggle,
// and the outlined airplane logo shape used in the UI and exported images.
import SwiftUI

enum AppBrand {
    static let name = "LogMate"
}

enum PrototypeTesting {
    // Testing only. Change to false before shipping the final product.
    static let enablesFlightReset = true
}

// The outlined airplane from the supplied LogMate logo, without the icon background.
// The same vector is used by SwiftUI and the exported story image.
struct LogMateLogo: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 22, y: 94))
        path.addLine(to: CGPoint(x: 86, y: 150))
        path.addLine(to: CGPoint(x: 22, y: 206))
        path.closeSubpath()
        path.move(to: CGPoint(x: 22, y: 150))
        path.addLine(to: CGPoint(x: 338, y: 150))
        path.move(to: CGPoint(x: 194, y: 150))
        path.addLine(to: CGPoint(x: 134, y: 18))
        path.addLine(to: CGPoint(x: 182, y: 18))
        path.addLine(to: CGPoint(x: 246, y: 150))
        path.move(to: CGPoint(x: 194, y: 150))
        path.addLine(to: CGPoint(x: 126, y: 282))
        path.addLine(to: CGPoint(x: 182, y: 282))
        path.addLine(to: CGPoint(x: 246, y: 150))
        path.move(to: CGPoint(x: 300, y: 114))
        path.addLine(to: CGPoint(x: 338, y: 150))
        path.addLine(to: CGPoint(x: 300, y: 187))
        let scale = min(rect.width / 360, rect.height / 300)
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: rect.midX - 180 * scale, ty: rect.midY - 150 * scale))
    }
}
