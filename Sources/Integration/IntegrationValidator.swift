import Foundation

/// Turns raw request arguments into validated, canonical values.
///
/// The router never sees an unvalidated argument. Validation is schema-driven
/// (from `IntegrationActionSpec`) plus a small per-action semantic pass.
enum IntegrationValidator {
    static func validate(request: IntegrationRequest,
                         spec: IntegrationActionSpec,
                         snapshot: IntegrationSnapshot,
                         coerce: Bool) throws -> [String: IntegrationValue] {
        let specsByName = Dictionary(uniqueKeysWithValues: spec.args.map { ($0.name, $0) })

        // Unknown keys are rejected: a typo must not silently do nothing, and a
        // newer client sending a new key must see a clear error at this version.
        for key in request.args.keys where specsByName[key] == nil {
            throw IntegrationError(.invalidArgument,
                                   "unknown argument '\(key)' for \(spec.id)",
                                   field: key)
        }

        var args: [String: IntegrationValue] = [:]
        for arg in spec.args {
            let raw = request.args[arg.name] ?? arg.defaultValue
            guard let raw else {
                if arg.required {
                    throw IntegrationError(.invalidArgument,
                                           "missing required argument '\(arg.name)'",
                                           field: arg.name)
                }
                continue
            }
            args[arg.name] = try coerceValue(raw, to: arg, coerce: coerce)
        }

        try validateSemantics(spec: spec, args: &args, snapshot: snapshot)
        return args
    }

    // MARK: - Types

    private static func coerceValue(_ raw: IntegrationValue,
                                    to arg: IntegrationArgSpec,
                                    coerce: Bool) throws -> IntegrationValue {
        switch (arg.type, raw) {
        case (.string(let maxLength), .string(let value)):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= maxLength else {
                throw IntegrationError(.invalidArgument,
                                       "'\(arg.name)' is longer than \(maxLength) characters",
                                       field: arg.name)
            }
            return .string(trimmed)

        case (.boolean, .bool(let value)):
            return .bool(value)

        case (.boolean, .string(let value)) where coerce:
            switch value.lowercased() {
            case "true", "1", "yes": return .bool(true)
            case "false", "0", "no": return .bool(false)
            default:
                throw IntegrationError(.invalidArgument,
                                       "'\(arg.name)' must be true or false",
                                       field: arg.name)
            }

        case (.integer(let min, let max), .int(let value)):
            guard (min...max).contains(value) else {
                throw IntegrationError(.invalidArgument,
                                       "'\(arg.name)' must be between \(min) and \(max)",
                                       field: arg.name)
            }
            return .int(value)

        case (.integer(let min, let max), .string(let value)) where coerce:
            guard let parsed = Int(value), (min...max).contains(parsed) else {
                throw IntegrationError(.invalidArgument,
                                       "'\(arg.name)' must be an integer between \(min) and \(max)",
                                       field: arg.name)
            }
            return .int(parsed)

        case (.uuid, .string(let value)):
            guard let uuid = UUID(uuidString: value) else {
                throw IntegrationError(.invalidArgument,
                                       "'\(arg.name)' is not a valid UUID",
                                       field: arg.name)
            }
            return .string(uuid.uuidString)

        case (.enumeration(let allowed), .string(let value)):
            guard let match = allowed.first(where: {
                $0.caseInsensitiveCompare(value) == .orderedSame
            }) else {
                throw IntegrationError(.invalidArgument,
                                       "'\(arg.name)' must be one of: \(allowed.joined(separator: ", "))",
                                       field: arg.name)
            }
            return .string(match)

        default:
            throw IntegrationError(.invalidArgument,
                                   "'\(arg.name)' has the wrong type",
                                   field: arg.name)
        }
    }

    // MARK: - Semantics

    private static func validateSemantics(spec: IntegrationActionSpec,
                                          args: inout [String: IntegrationValue],
                                          snapshot: IntegrationSnapshot) throws {
        switch spec.id {
        case "targets.add", "targets.update":
            if let raw = args["pattern"]?.stringValue {
                args["pattern"] = .string(try normalizeTargetPattern(raw, field: "pattern"))
            }
            if spec.id == "targets.update", args["pattern"] == nil, args["enabled"] == nil {
                throw IntegrationError(.invalidArgument,
                                       "targets.update needs pattern or enabled",
                                       field: "pattern")
            }
            if spec.id == "targets.add", snapshot.targets.count >= 500 {
                throw IntegrationError(.conflict,
                                       "target list is full (500 rules)")
            }

        case "targets.remove":
            let hasID = args["id"] != nil
            let hasPattern = args["pattern"] != nil
            guard hasID != hasPattern else {
                throw IntegrationError(.invalidArgument,
                                       "pass exactly one of id or pattern",
                                       field: hasID ? "pattern" : "id")
            }
            if let raw = args["pattern"]?.stringValue {
                args["pattern"] = .string(try normalizeTargetPattern(raw, field: "pattern"))
            }

        case "targets.clear":
            guard args["confirm"]?.boolValue == true else {
                throw IntegrationError(.invalidArgument,
                                       "targets.clear requires confirm=true",
                                       field: "confirm")
            }

        case "routing.explain":
            let host = args["host"]?.stringValue ?? ""
            guard isValidHost(host) else {
                throw IntegrationError(.invalidArgument,
                                       "'host' is not a valid hostname",
                                       field: "host")
            }
            if let bundle = args["bundleID"]?.stringValue, !isValidBundleID(bundle) {
                throw IntegrationError(.invalidArgument,
                                       "'bundleID' is not a valid bundle identifier",
                                       field: "bundleID")
            }

        case "apps.rule.set":
            let kind = AppRuleKeyKind(rawValue: args["keyKind"]?.stringValue ?? "") ?? .bundle
            let key = args["key"]?.stringValue ?? ""
            try validateAppKey(key, kind: kind)

        case "apps.rule.remove":
            let hasID = args["id"] != nil
            let hasKey = args["key"] != nil
            guard hasID != hasKey else {
                throw IntegrationError(.invalidArgument,
                                       "pass exactly one of id or key+keyKind",
                                       field: hasID ? "key" : "id")
            }
            if hasKey {
                guard let kindRaw = args["keyKind"]?.stringValue,
                      let kind = AppRuleKeyKind(rawValue: kindRaw) else {
                    throw IntegrationError(.invalidArgument,
                                           "keyKind is required with key",
                                           field: "keyKind")
                }
                try validateAppKey(args["key"]?.stringValue ?? "", kind: kind)
            }

        case "apps.resolve":
            let selectors = ["bundleID", "path", "pid"].filter { args[$0] != nil }
            guard selectors.count == 1 else {
                throw IntegrationError(.invalidArgument,
                                       "pass exactly one of bundleID, path or pid",
                                       field: selectors.isEmpty ? "bundleID" : selectors[1])
            }
            if let bundle = args["bundleID"]?.stringValue, !isValidBundleID(bundle) {
                throw IntegrationError(.invalidArgument,
                                       "'bundleID' is not a valid bundle identifier",
                                       field: "bundleID")
            }
            if let path = args["path"]?.stringValue, !isAbsolutePath(path) {
                throw IntegrationError(.invalidArgument,
                                       "'path' must be absolute",
                                       field: "path")
            }

        case "ui.open":
            if args["section"] != nil, args["pane"]?.stringValue != "settings" {
                throw IntegrationError(.invalidArgument,
                                       "section is only valid with pane=settings",
                                       field: "section")
            }
            if let raw = args["revealPattern"]?.stringValue {
                args["revealPattern"] = .string(try normalizeTargetPattern(raw, field: "revealPattern"))
            }

        case "presets.apply":
            let name = args["name"]?.stringValue ?? ""
            guard !name.isEmpty else {
                throw IntegrationError(.invalidArgument, "'name' must not be empty", field: "name")
            }

        default:
            break
        }
    }

    // MARK: - Field rules

    /// Canonical target pattern: lowercased, port stripped, trailing dots
    /// removed, one optional leading `*.` wildcard. Mirrors
    /// `RoutingEngine.normalize` without pulling the routing engine in.
    static func normalizeTargetPattern(_ raw: String, field: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else {
            throw IntegrationError(.invalidArgument, "'\(field)' must not be empty", field: field)
        }
        guard value.count <= 253 else {
            throw IntegrationError(.invalidArgument, "'\(field)' is too long", field: field)
        }
        guard !value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.generalCategory == .control
        }) else {
            throw IntegrationError(.invalidArgument,
                                   "'\(field)' must not contain whitespace", field: field)
        }

        // Strip an explicit port, matching AppModel.addTarget's normalization.
        if value.hasPrefix("[") {
            if let close = value.firstIndex(of: "]") {
                value = String(value[value.index(after: value.startIndex)..<close])
            }
        } else if value.filter({ $0 == ":" }).count == 1,
                  let idx = value.lastIndex(of: ":") {
            let port = value[value.index(after: idx)...]
            if !port.isEmpty, port.allSatisfy({ $0.isNumber }) {
                value = String(value[..<idx])
            }
        }
        while value.hasSuffix(".") && value != "*" { value.removeLast() }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_:[]*")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw IntegrationError(.invalidArgument,
                                   "'\(field)' contains characters that are not allowed",
                                   field: field)
        }
        guard value != "*", !value.isEmpty else {
            throw IntegrationError(.invalidArgument,
                                   "'\(field)' needs a host, not a bare wildcard",
                                   field: field)
        }
        guard !value.hasSuffix(":") else {
            throw IntegrationError(.invalidArgument,
                                   "'\(field)' ends with an empty port",
                                   field: field)
        }
        if value.contains("*") {
            guard value.hasPrefix("*."), !value.dropFirst(2).contains("*"),
                  value.dropFirst(2).count > 1 else {
                throw IntegrationError(.invalidArgument,
                                       "wildcards must look like *.example.com",
                                       field: field)
            }
        }
        return value
    }

    static func isValidHost(_ raw: String) -> Bool {
        (try? normalizeTargetPattern(raw, field: "host")) != nil
    }

    static func isValidBundleID(_ value: String) -> Bool {
        guard (1...255).contains(value.count), let first = value.first else { return false }
        guard first.isASCII, first.isLetter || first.isNumber else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.split(separator: "/").contains("..")
    }

    private static func validateAppKey(_ key: String, kind: AppRuleKeyKind) throws {
        guard !key.isEmpty else {
            throw IntegrationError(.invalidArgument, "'key' must not be empty", field: "key")
        }
        switch kind {
        case .bundle:
            guard isValidBundleID(key) else {
                throw IntegrationError(.invalidArgument,
                                       "'key' is not a valid bundle identifier",
                                       field: "key")
            }
        case .executable:
            guard isAbsolutePath(key) else {
                throw IntegrationError(.invalidArgument,
                                       "'key' must be an absolute path",
                                       field: "key")
            }
            guard FileManager.default.isExecutableFile(atPath: key) else {
                throw IntegrationError(.invalidArgument,
                                       "no executable at '\(key)'",
                                       field: "key")
            }
        case .executableName:
            guard !key.contains("/") else {
                throw IntegrationError(.invalidArgument,
                                       "'key' must be a bare executable name",
                                       field: "key")
            }
        }
    }
}
