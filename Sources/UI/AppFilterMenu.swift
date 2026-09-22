import AppKit
import SwiftUI

/// An app that appears in the current feed, for the feed's app filter.
struct AppFilterOption: Identifiable, Equatable {
    let id: String        // bundle id, or the app name for bundle-less processes
    let name: String
    let bundleId: String?
    let count: Int
}

/// Feed app filter: a **select** (not free text) whose options are the apps
/// present in the feed, with a search box inside. The option list is snapshotted
/// when the popover opens so it never reorders under the user while it is open.
struct AppFilterMenu: View {
    let options: [AppFilterOption]
    @Binding var selection: String?

    @State private var showPopover = false
    @State private var query = ""
    @State private var snapshot: [AppFilterOption] = []

    private var selected: AppFilterOption? {
        options.first { $0.id == selection }
    }

    var body: some View {
        Button {
            snapshot = options
            query = ""
            showPopover = true
        } label: {
            HStack(spacing: 6) {
                if let selected {
                    icon(selected.bundleId)
                        .frame(width: 16, height: 16)
                    Text(selected.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("All apps")
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 140)
        }
        .buttonStyle(.bordered)
        .help("Filter the feed by app")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) { popover }
    }

    private var filteredOptions: [AppFilterOption] {
        guard !query.isEmpty else { return snapshot }
        return snapshot.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    private var popover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            Divider()
            ScrollView {
                // A plain VStack (not Lazy) so the popover gets a correct height
                // on first open; the list is small.
                VStack(spacing: 0) {
                    row(id: nil, name: "All apps", bundleId: nil, count: nil)
                    ForEach(filteredOptions) { option in
                        row(id: option.id, name: option.name, bundleId: option.bundleId, count: option.count)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: listHeight)
        }
        .frame(width: 260)
    }

    private var listHeight: CGFloat {
        let rowHeight: CGFloat = 24
        let rows = filteredOptions.count + 1
        return min(max(CGFloat(rows) * rowHeight + 8, rowHeight * 2), 280)
    }

    private func row(id: String?, name: String, bundleId: String?, count: Int?) -> some View {
        Button {
            selection = id
            showPopover = false
        } label: {
            HStack(spacing: 8) {
                if id == nil {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.secondary)
                } else {
                    icon(bundleId)
                        .frame(width: 16, height: 16)
                }
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let count {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if selection == id {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func icon(_ bundleId: String?) -> some View {
        if let image = AppIcon.image(bundleId: bundleId, path: nil) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.tertiary)
        }
    }
}
