import SwiftUI

/// An inline "?" button that shows a short explanation (with optional example)
/// in a popover. Used throughout Settings to make every option self-documenting.
struct HelpPopover: View {
    let text: String
    var example: String?

    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown) {
            VStack(alignment: .leading, spacing: 8) {
                codeAwareText(text, baseFont: .callout)
                if let example {
                    codeAwareText(example, baseFont: .caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(width: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A Form section header with a title and a help popover.
struct HelpSectionHeader: View {
    let title: String
    let help: String
    var example: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            HelpPopover(text: help, example: example)
        }
    }
}
