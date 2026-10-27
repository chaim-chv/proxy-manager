import Foundation

// Renders the external-control action table for the website and docs.
//
//   xcrun swiftc -swift-version 5 -O \
//     Sources/Config/ConfigModels.swift \
//     Sources/Integration/IntegrationValue.swift \
//     Sources/Integration/IntegrationProtocol.swift \
//     Sources/Integration/IntegrationAction.swift \
//     Tools/integration-reference/main.swift -o /tmp/actions
//   /tmp/actions > docs/integration-actions.html
//
// The output is pasted between the BEGIN/END markers in
// `docs/integration.html` on the gh-pages branch. Keeping it generated means a
// renamed action cannot silently drift from the site.

func escape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func typeLabel(_ type: IntegrationArgType) -> String {
    switch type {
    case .string: return "string"
    case .boolean: return "bool"
    case .integer: return "int"
    case .uuid: return "uuid"
    case .enumeration: return "enum"
    }
}

func argLabel(_ arg: IntegrationArgSpec) -> String {
    let name = escape(arg.name)
    let type = typeLabel(arg.type)
    let optional = arg.required ? "" : "?"
    return "<code>\(name)</code>:<span class=\"docs-arg-type\">\(type)\(optional)</span>"
}

print("<!-- Generated from IntegrationActions.all by Tools/integration-reference. Do not edit by hand. -->")
print("<table class=\"docs-table\">")
print("<thead><tr><th>Action</th><th>Arguments</th><th>Kind</th></tr></thead>")
print("<tbody>")
for spec in IntegrationActions.all {
    let args = spec.args.isEmpty
        ? "—"
        : spec.args.map(argLabel).joined(separator: ", ")
    print("<tr><td><code>\(escape(spec.id))</code></td><td>\(args)</td><td>\(spec.risk.rawValue)</td></tr>")
}
print("</tbody>")
print("</table>")
