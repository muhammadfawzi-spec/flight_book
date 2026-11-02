// App-wide theme: dark/light toggle (persisted), the palette, and the
// animated window-snapshot crossfade between themes.
import SwiftUI
import UIKit
import Combine

@MainActor final class AppTheme: ObservableObject {
    @Published var dark = (UserDefaults.standard.object(forKey: "isDarkMode") as? Bool) ?? true
    private var changing = false
    var background: Color { Color(hex: dark ? 0x080B0E : 0xEEF1F3) }
    var surface: Color { Color(hex: dark ? 0x12181D : 0xFFFFFF) }
    var raised: Color { Color(hex: dark ? 0x182127 : 0xF4F6F7) }
    var line: Color { Color(hex: dark ? 0x283138 : 0xDDE3E7) }
    var text: Color { Color(hex: dark ? 0xF5F7F8 : 0x0E1B2C) }
    var muted: Color { Color(hex: dark ? 0x8D969D : 0x66727E) }
    var accent: Color { Color(hex: dark ? 0xFFC548 : 0xEF9B00) }
    var cyan: Color { Color(hex: dark ? 0x19D7EE : 0x08A7C0) }
    func toggle() {
        guard !changing else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow)
        let snapshot = window?.snapshotView(afterScreenUpdates: false)
        if let window, let snapshot {
            snapshot.frame = window.bounds
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            window.addSubview(snapshot)
            changing = true
        }
        dark.toggle()
        UserDefaults.standard.set(dark, forKey: "isDarkMode")
        guard let snapshot else { return }
        UIView.animate(withDuration: 0.85, delay: 0.08, options: [.curveEaseInOut]) {
            snapshot.alpha = 0
        } completion: { _ in
            snapshot.removeFromSuperview(); self.changing = false
        }
    }
}
