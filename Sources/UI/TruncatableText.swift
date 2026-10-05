import SwiftUI

/// A `Text` that shows the full string in the immediate hover tooltip **only
/// when the rendered text is actually ellipsised**. Drop-in replacement for the
/// common `Text(x).lineLimit(1).truncationMode(.middle)` pattern, so a clipped
/// value is always recoverable on hover without tooltips appearing on text that
/// is already fully visible.
struct TruncatableText: View {
    let text: String
    /// `nil` inherits the ambient font (same as a plain `Text` with no `.font`).
    var font: Font? = nil
    var lineLimit: Int = 1
    var truncationMode: Text.TruncationMode = .middle
    var monospacedDigit: Bool = false
    var alignment: Alignment = .leading
    /// Shown on hover instead of `text` when the label is clipped (e.g. to append
    /// a bundle id to a truncated app name).
    var tooltip: String? = nil

    init(_ text: String, font: Font? = nil, lineLimit: Int = 1,
         truncationMode: Text.TruncationMode = .middle,
         monospacedDigit: Bool = false, alignment: Alignment = .leading,
         tooltip: String? = nil) {
        self.text = text
        self.font = font
        self.lineLimit = lineLimit
        self.truncationMode = truncationMode
        self.monospacedDigit = monospacedDigit
        self.alignment = alignment
        self.tooltip = tooltip
    }

    @State private var available: CGSize = .zero
    @State private var required: CGSize = .zero

    private var isTruncated: Bool {
        if lineLimit == 1 {
            return TruncationDetector.isTruncated(requiredWidth: required.width,
                                                  availableWidth: available.width)
        }
        return TruncationDetector.isTruncated(requiredHeight: required.height,
                                              availableHeight: available.height)
    }

    var body: some View {
        styledText
            .lineLimit(lineLimit)
            .truncationMode(truncationMode)
            .background(sizeReader($available))
            .background(alignment: alignment) { requiredMeasurement }
            .hoverTooltip(isTruncated ? (tooltip ?? text) : nil)
    }

    private var styledText: Text {
        var text = Text(self.text)
        if monospacedDigit { text = text.monospacedDigit() }
        if let font { text = text.font(font) }
        return text
    }

    @ViewBuilder private var requiredMeasurement: some View {
        if lineLimit == 1 {
            styledText.fixedSize()
                .hidden()
                .background(sizeReader($required))
        } else {
            styledText.fixedSize(horizontal: false, vertical: true)
                .frame(width: available.width, alignment: alignment)
                .hidden()
                .background(sizeReader($required))
        }
    }

    private func sizeReader(_ binding: Binding<CGSize>) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { binding.wrappedValue = proxy.size }
                .onChange(of: proxy.size) { _, size in binding.wrappedValue = size }
        }
    }
}
