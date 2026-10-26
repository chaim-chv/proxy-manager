import Foundation

/// The maximum reach a caller is granted. There is no `admin` scope: this
/// integration deliberately stops at routing/targets/per-app control, so every
/// exposed action is either a read, a window action, or a routing-policy change.
enum IntegrationScope: String, Codable, Equatable {
    case read
    case control

    var rank: Int {
        switch self {
        case .read: return 0
        case .control: return 1
        }
    }
}

/// Who sent a request. The adapter decides the scope; the router only enforces
/// it. `identityKey` scopes rate limits and audit entries, never authorization
/// (the adapter has already authorized the caller by the time the router runs).
enum IntegrationSource: Equatable {
    case urlScheme(senderPID: Int32?)
    case appIntent
    case xpc(pid: Int32, bundleID: String?, teamID: String?, scope: IntegrationScope)
    case commandLine
    case test

    var kind: String {
        switch self {
        case .urlScheme: return "url"
        case .appIntent: return "intent"
        case .xpc: return "xpc"
        case .commandLine: return "cli"
        case .test: return "test"
        }
    }

    var scope: IntegrationScope {
        switch self {
        case .xpc(_, _, _, let scope): return scope
        // URL and App Intents are OS-level entry points rather than an
        // authenticated API, so they are capped at `control` and further
        // restricted action-by-action by the exposure flags.
        case .urlScheme, .appIntent, .commandLine, .test: return .control
        }
    }

    var identityKey: String {
        switch self {
        case .urlScheme: return "url"
        case .appIntent: return "intent"
        case .xpc(let pid, let bundleID, let teamID, _):
            if let bundleID { return "xpc:\(bundleID)" }
            if let teamID { return "xpc:\(teamID)" }
            return "xpc:pid:\(pid)"
        case .commandLine: return "cli"
        case .test: return "test"
        }
    }

    var auditSource: IntegrationAuditSource {
        switch self {
        case .urlScheme(let pid):
            return IntegrationAuditSource(kind: "url", bundleID: nil, pid: pid,
                                          teamID: nil, scope: nil)
        case .appIntent:
            return IntegrationAuditSource(kind: "intent", bundleID: nil, pid: nil,
                                          teamID: nil, scope: nil)
        case .xpc(let pid, let bundleID, let teamID, let scope):
            return IntegrationAuditSource(kind: "xpc", bundleID: bundleID, pid: pid,
                                          teamID: teamID, scope: scope.rawValue)
        case .commandLine:
            return IntegrationAuditSource(kind: "cli", bundleID: nil, pid: nil,
                                          teamID: nil, scope: nil)
        case .test:
            return IntegrationAuditSource(kind: "test", bundleID: nil, pid: nil,
                                          teamID: nil, scope: nil)
        }
    }
}

/// The protocol version. Bumped only for a breaking envelope change; actions are
/// added without a bump and discovered through `capabilities`.
enum IntegrationProtocol {
    static let version = 1
}

struct IntegrationRequest: Codable, Equatable {
    var v: Int
    var id: String
    var action: String
    var args: [String: IntegrationValue]

    init(id: String = UUID().uuidString,
         action: String,
         args: [String: IntegrationValue] = [:],
         v: Int = IntegrationProtocol.version) {
        self.v = v
        self.id = id
        self.action = action
        self.args = args
    }

    private enum CodingKeys: String, CodingKey { case v, id, action, args }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? c.decode(Int.self, forKey: .v)) ?? IntegrationProtocol.version
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        action = (try? c.decode(String.self, forKey: .action)) ?? ""
        args = (try? c.decode([String: IntegrationValue].self, forKey: .args)) ?? [:]
    }
}

struct IntegrationResult: Codable, Equatable {
    var v: Int
    var id: String
    var action: String
    var ok: Bool
    var changed: Bool
    var data: [String: IntegrationValue]
    var error: IntegrationError?
    var auditId: String
    var durationMs: Int

    init(id: String,
         action: String,
         ok: Bool,
         changed: Bool = false,
         data: [String: IntegrationValue] = [:],
         error: IntegrationError? = nil,
         auditId: String = UUID().uuidString,
         durationMs: Int = 0,
         v: Int = IntegrationProtocol.version) {
        self.v = v
        self.id = id
        self.action = action
        self.ok = ok
        self.changed = changed
        self.data = data
        self.error = error
        self.auditId = auditId
        self.durationMs = durationMs
    }

    private enum CodingKeys: String, CodingKey {
        case v, id, action, ok, changed, data, error, auditId, durationMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? c.decode(Int.self, forKey: .v)) ?? IntegrationProtocol.version
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        action = (try? c.decode(String.self, forKey: .action)) ?? ""
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        changed = (try? c.decode(Bool.self, forKey: .changed)) ?? false
        data = (try? c.decode([String: IntegrationValue].self, forKey: .data)) ?? [:]
        error = try? c.decode(IntegrationError.self, forKey: .error)
        auditId = (try? c.decode(String.self, forKey: .auditId)) ?? ""
        durationMs = (try? c.decode(Int.self, forKey: .durationMs)) ?? 0
    }
}

enum IntegrationErrorCode: String, Codable, Equatable {
    case badRequest = "bad_request"
    case unknownAction = "unknown_action"
    case invalidArgument = "invalid_argument"
    case unauthorized
    case forbidden
    case notFound = "not_found"
    case conflict
    case busy
    case timeout
    case unavailable
    case unsupported
    case shuttingDown = "shutting_down"
    case requiresUserAction = "requires_user_action"
    case internalError = "internal"
}

struct IntegrationError: Error, Codable, Equatable {
    var code: IntegrationErrorCode
    var message: String
    var field: String?

    init(_ code: IntegrationErrorCode, _ message: String, field: String? = nil) {
        self.code = code
        self.message = message
        self.field = field
    }
}

struct IntegrationAuditSource: Codable, Equatable {
    var kind: String
    var bundleID: String?
    var pid: Int32?
    var teamID: String?
    var scope: String?
}

struct IntegrationAuditEntry: Codable, Equatable {
    var v: Int
    var ts: String
    var id: String
    var auditId: String
    var source: IntegrationAuditSource
    var action: String
    var args: [String: IntegrationValue]
    var ok: Bool
    var changed: Bool
    var errorCode: String?
    var durationMs: Int

    init(id: String,
         auditId: String,
         source: IntegrationAuditSource,
         action: String,
         args: [String: IntegrationValue],
         ok: Bool,
         changed: Bool,
         errorCode: String?,
         durationMs: Int,
         ts: String = IntegrationAuditEntry.timestamp(),
         v: Int = 1) {
        self.v = v
        self.ts = ts
        self.id = id
        self.auditId = auditId
        self.source = source
        self.action = action
        self.args = args
        self.ok = ok
        self.changed = changed
        self.errorCode = errorCode
        self.durationMs = durationMs
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
