import AppKit

/// Measurement for the shared tooltip window, kept AppKit-only so the harness
/// can pin down the wrapping behavior.
///
/// `boundingRect(with:options:)` must be given the label's real attributes;
/// without `attributes:` it measures with the default 12 pt font, so a 10 pt
/// tooltip label got a frame that was too wide and too short for wrapped text.
enum TooltipMetrics {
    /// Size of `text` wrapped at `maxWidth`, with an unbounded height so long
    /// multi-line strings are never clipped. Width never exceeds `maxWidth`
    /// (an unbreakable word is clipped by the frame, not the measurement) and
    /// both dimensions are non-negative.
    static func size(text: String, font: NSFont, maxWidth: CGFloat) -> NSSize {
        let width = max(0, maxWidth)
        guard width > 0 else { return .zero }

        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return NSSize(
            width: max(0, min(ceil(rect.width), width)),
            height: max(0, ceil(rect.height))
        )
    }
}
