import Foundation

final class ShellEnvInjector {
    static let blockStart = "# >>> proxy-manager >>>"
    static let blockEnd = "# <<< proxy-manager <<<"

    private let configStore: ConfigStore

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    var envDir: URL { configStore.envDir }
    var envFileURL: URL { configStore.envFileURL }

    func writeEnvFile(port: UInt16, bindHost: String, tunnelHost: String) {
        // Local clients reach the proxy on a connectable address; a wildcard
        // bind (`0.0.0.0`/empty) is not one, so map it to loopback. This also
        // keeps the env in sync with the system proxy, which is always 127.0.0.1.
        let rawHost = (bindHost.isEmpty || bindHost == "0.0.0.0") ? "127.0.0.1" : bindHost
        guard let host = Self.sanitizedHost(rawHost) else {
            Log.system.error("shell env: invalid bind host, not writing env file")
            return
        }
        var noProxy = "127.0.0.1,localhost,::1"
        let t = tunnelHost.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, t != "127.0.0.1", t != "localhost", let th = Self.sanitizedHost(t) {
            noProxy += ",\(th)"
        }
        let content = """
        # Managed by Proxy Manager — do not edit by hand.
        export HTTP_PROXY="http://\(host):\(port)"
        export HTTPS_PROXY="http://\(host):\(port)"
        export NO_PROXY="\(noProxy)"
        export PROXY_MANAGER_ACTIVE="1"
        """
        try? FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)
        try? content.write(to: envFileURL, atomically: true, encoding: .utf8)
    }

    /// Hostnames/IPs only. Anything that could break out of the quoted `export`
    /// value (quotes, `$`, backticks, whitespace, newlines) is rejected.
    static func sanitizedHost(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")
        guard t.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return t
    }

    func removeEnvFile() {
        try? FileManager.default.removeItem(at: envFileURL)
    }

    func install(rcFiles: [String]) {
        for path in rcFiles {
            let expanded = expand(path)
            guard FileManager.default.fileExists(atPath: expanded) else { continue }
            guard var content = try? String(contentsOfFile: expanded, encoding: .utf8) else { continue }
            if content.contains(Self.blockStart) { continue }
            let sourceLine = "[ -f \"$HOME/.config/proxy-manager/env.sh\" ] && . \"$HOME/.config/proxy-manager/env.sh\""
            let block = "\n\(Self.blockStart)\n\(sourceLine)\n\(Self.blockEnd)\n"
            content += block
            try? content.write(toFile: expanded, atomically: true, encoding: .utf8)
        }
    }

    func remove(rcFiles: [String]) {
        for path in rcFiles {
            let expanded = expand(path)
            guard FileManager.default.fileExists(atPath: expanded) else { continue }
            guard var content = try? String(contentsOfFile: expanded, encoding: .utf8) else { continue }
            while let start = content.range(of: Self.blockStart),
                  let end = content.range(of: Self.blockEnd, options: [], range: start.upperBound..<content.endIndex) {
                let full = start.lowerBound..<end.upperBound
                content.removeSubrange(full)
            }
            content = content.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            try? content.write(toFile: expanded, atomically: true, encoding: .utf8)
        }
    }

    private func expand(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        }
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return path
    }
}
