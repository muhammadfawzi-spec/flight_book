// The shared visual language: hex Color initializer, card styles and tones,
// accent buttons, section headings, the SheetFrame modal chrome, and the
// keyboard-dismiss support (tap-outside + Done control).
import SwiftUI
import UIKit
import Combine

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

enum CardTone { case neutral, blue, green, airport }

struct CardStyle: ViewModifier {
    @EnvironmentObject var theme: AppTheme
    var padding: CGFloat = 18
    var tone: CardTone = .neutral
    private var colors: [Color] {
        switch tone {
        case .neutral: return theme.dark ? [Color(hex: 0x17252C), Color(hex: 0x121A1F), Color(hex: 0x0E151A)] : [.white, Color(hex: 0xF1F5F6)]
        case .blue: return theme.dark ? [Color(hex: 0x243D49), Color(hex: 0x14222A), Color(hex: 0x0E171C)] : [Color(hex: 0xFAFDFF), Color(hex: 0xE5F1F4)]
        case .green: return theme.dark ? [Color(hex: 0x2A342F), Color(hex: 0x17211F), Color(hex: 0x111817)] : [Color(hex: 0xFBFDF8), Color(hex: 0xEDF3E9)]
        case .airport: return theme.dark ? [Color(hex: 0x172932), Color(hex: 0x10171C)] : [.white, Color(hex: 0xEEF5F7)]
        }
    }
    func body(content: Content) -> some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(LinearGradient(colors: [Color.white.opacity(theme.dark ? 0.075 : 0.9), theme.line.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: (theme.dark ? Color.black : Color(hex: 0x273F4B)).opacity(theme.dark ? 0.16 : 0.11), radius: 12, x: 0, y: 8)
    }
}

extension View {
    func logbookCard(_ padding: CGFloat = 18, tone: CardTone = .neutral) -> some View { modifier(CardStyle(padding: padding, tone: tone)) }
}

struct AccentButtonLabel: View {
    @EnvironmentObject var theme: AppTheme
    var title: String
    var body: some View {
        Text(title).font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(Color(hex: 0x15202A)).frame(maxWidth: .infinity)
            .padding(.vertical, 16).background(theme.accent).clipShape(Capsule())
    }
}

struct AccentButton: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            AccentButtonLabel(title: title)
        }.buttonStyle(.plain)
    }
}

struct SectionHeading: View {
    var title: String
    var body: some View { Text(title).font(.system(size: 23, weight: .bold, design: .rounded)) }
}

struct SheetFrame<Content: View>: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    let title: String
    let subtitle: String?
    let content: Content
    let scrollTarget: ScanScrollTarget?
    let onClose: (() -> Void)?
    @State private var keyboardVisible = false
    init(title: String, subtitle: String? = nil, scrollTarget: ScanScrollTarget? = nil, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.scrollTarget = scrollTarget
        self.onClose = onClose
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 27, weight: .bold, design: .rounded))
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(theme.muted) }
                }
                Spacer()
                Button { if let onClose { onClose() } else { dismiss() } } label: {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.muted).frame(width: 42, height: 42)
                        .background(theme.raised).clipShape(Circle())
                }.accessibilityLabel("Close")
            }.padding(20)
            Divider().overlay(theme.line)
            ScrollViewReader { proxy in
                ScrollView { content.padding(20) }
                    .scrollDismissesKeyboard(.never)
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("scan-" + target.field, anchor: .center) }
                    }
            }
        }.background(theme.background).foregroundStyle(theme.text)
            .background(KeyboardDismissSupport())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if keyboardVisible {
                    HStack {
                        Spacer()
                        Button { KeyboardDismissSupport.dismiss() } label: {
                            Label("Done", systemImage: "keyboard.chevron.compact.down")
                                .font(.subheadline.bold()).foregroundStyle(theme.cyan)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(theme.raised).clipShape(Capsule())
                                .overlay(Capsule().stroke(theme.line, lineWidth: 1))
                        }.accessibilityLabel("Dismiss keyboard")
                    }.padding(.horizontal, 20).padding(.vertical, 8)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
            .preferredColorScheme(theme.dark ? .dark : .light)
            .presentationDragIndicator(.visible)
    }
}

// A tap recognizer does not compete with a drag/scroll and never cancels controls.
// Number/decimal pads have a compact app-styled Done control in SheetFrame.
struct KeyboardDismissSupport: UIViewRepresentable {
    static func dismiss() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
    final class Anchor: UIView {
        var attach: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); attach?(window) }
    }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var window: UIWindow?
        var tap: UITapGestureRecognizer?
        func attach(_ next: UIWindow?) {
            guard window !== next else { return }
            if let tap { window?.removeGestureRecognizer(tap) }
            window = next
            guard let next else { tap = nil; return }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
            recognizer.cancelsTouchesInView = false; recognizer.delegate = self
            next.addGestureRecognizer(recognizer); tap = recognizer
        }
        @objc func tapped() { KeyboardDismissSupport.dismiss() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView || current is UIControl { return false }
                // UIKit's own keyboard must keep receiving digit and delete taps.
                let name = String(describing: type(of: current))
                if name.contains("Keyboard") || name.contains("InputSet") { return false }
                view = current.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> Anchor {
        let view = Anchor(); view.isUserInteractionEnabled = false
        view.attach = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) { context.coordinator.attach(view.window) }
    static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) { coordinator.attach(nil) }
}
