import Foundation

/// A parsed `proxymanager://` command. The URL transport is unauthenticated, so
/// this parser only builds the request; the router still enforces which actions
/// a URL may reach.
struct URLCommand: Equatable {
    let action: String
    let args: [String: IntegrationValue]
}

enum URLCommandError: Error, Equatable {
    case notOurScheme
    case unsupportedVersion(String)
    case malformed(String)
}

enum URLCommandParser {
    static let scheme = "proxymanager"
    static let version = "v1"
    static let maxLength = 2_048
    static let maxQueryItems = 20

    /// `proxymanager://v1/routing/toggle?force=true`
    ///
    /// The version is the host so it can never be confused with an action path.
    /// A bare `proxymanager://v1` opens the dashboard.
    static func parse(_ url: URL) -> Result<URLCommand, URLCommandError> {
        guard url.scheme?.lowercased() == scheme else {
            return .failure(.notOurScheme)
        }
        guard url.absoluteString.count <= maxLength else {
            return .failure(.malformed("URL is longer than \(maxLength) characters"))
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.malformed("URL could not be parsed"))
        }
        guard components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil else {
            return .failure(.malformed("user, password, port and fragment are not allowed"))
        }

        let host = (components.host ?? "").lowercased()
        guard host == version else {
            return .failure(.unsupportedVersion(host.isEmpty ? "(none)" : host))
        }

        let items = components.queryItems ?? []
        guard items.count <= maxQueryItems else {
            return .failure(.malformed("more than \(maxQueryItems) arguments"))
        }

        var path = components.path
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }

        let action: String
        if path.isEmpty {
            action = "ui.open"
        } else {
            action = path.replacingOccurrences(of: "/", with: ".")
        }
        guard isValidAction(action) else {
            return .failure(.malformed("invalid action '\(action)'"))
        }

        var args: [String: IntegrationValue] = [:]
        if path.isEmpty {
            // A bare link is the "open the app" shortcut.
            args["pane"] = .string("dashboard")
        }
        for item in items {
            let name = item.name
            guard !name.isEmpty else {
                return .failure(.malformed("an argument has no name"))
            }
            guard args[name] == nil else {
                return .failure(.malformed("duplicate argument '\(name)'"))
            }
            args[name] = .string(item.value ?? "")
        }

        return .success(URLCommand(action: action, args: args))
    }

    private static func isValidAction(_ action: String) -> Bool {
        guard !action.isEmpty, action.count <= 64, !action.contains("..") else {
            return false
        }
        return action.range(of: #"^[a-z][a-z0-9.]*$"#, options: .regularExpression) != nil
    }
}
