// Small shared controls: LogField (a labeled text input with a scan-review
// hook) and SegmentButtonStyle (the full-width segment button look).
import SwiftUI

struct SegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 18, weight: .heavy, design: .rounded))
            .frame(maxWidth: .infinity).frame(height: 52).contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct LogField: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.scanReviewPresentation) var review
    var title: String
    @Binding var value: String
    var hint = ""
    var keyboard: UIKeyboardType = .default
    private var reviewKey: String? { ScanReviewFields.key(title) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !review.isTracked(reviewKey) { Text(title).font(.system(size: 14)).foregroundStyle(theme.muted) }
            TextField(hint, text: Binding(get: { value }, set: { value = $0; if let key = ScanReviewFields.key(title) { review.edited?(key) } }), axis: reviewKey == "notes" ? .vertical : .horizontal)
                .lineLimit(reviewKey == "notes" ? 1...6 : 1...1)
                .keyboardType(keyboard).autocorrectionDisabled()
                .padding(14).background(review.needsReview(reviewKey) ? ScanReviewColors.warning(theme.dark).opacity(theme.dark ? 0.10 : 0.07) : theme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(review.needsReview(reviewKey) ? ScanReviewColors.warning(theme.dark).opacity(0.55) : theme.line))
        }.frame(maxWidth: .infinity, alignment: .leading).scanField(reviewKey, label: title)
    }
}
