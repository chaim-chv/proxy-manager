import AppKit

/// Decides whether a label is being ellipsised, and what its tooltip should be.
///
/// Kept free of SwiftUI so the standalone harness (`Tests/UIHarness`) can test
/// it directly and the AppKit feed cells can reuse it. SwiftUI call sites go
/// through `TruncatableText`, which measures itself and delegates the decision
/// here.
enum TruncationDetector {
    /// Sub-pixel layout differences must not flip a label between "fits" and
    /// "truncated".
    static let epsilon: CGFloat = 0.5

    /// Single-line: the text needs more width than it was given.
    static func isTruncated(requiredWidth: CGFloat, availableWidth: CGFloat) -> Bool {
        guard requiredWidth > 0, availableWidth > 0 else { return false }
        return requiredWidth > availableWidth + epsilon
    }

    /// Multi-line: the wrapped text needs more height than it was given.
    static func isTruncated(requiredHeight: CGFloat, availableHeight: CGFloat) -> Bool {
        guard requiredHeight > 0, availableHeight > 0 else { return false }
        return requiredHeight > availableHeight + epsilon
    }

    /// Width `text` occupies on a single line in `font`.
    static func requiredWidth(of text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The full text when it does not fit `availableWidth`, otherwise `nil` — so
    /// fully-visible labels get no tooltip at all.
    static func tooltip(text: String, availableWidth: CGFloat, font: NSFont) -> String? {
        guard !text.isEmpty else { return nil }
        return isTruncated(requiredWidth: requiredWidth(of: text, font: font),
                           availableWidth: availableWidth) ? text : nil
    }
}
