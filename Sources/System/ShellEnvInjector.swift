import Foundation

final class ShellEnvInjector {
    static let blockStart = "# >>> proxy-manager >>>"
    static let blockEnd = "# <<< proxy-manager <<<"

    /// Removal must not depend on the current config (the watchdog may hold a
    /// stale snapshot), so always sweep the shell's default rc file too.
    static let defaultRCFiles = ["~/.zshrc"]

    /// Fish/csh use different syntax; appending a POSIX `export` block breaks
    /// those shells, so installation is restricted to POSIX-style rc files.
    private static let warnedLock = NSLock()
    private static var warnedUnsupportedPaths = Set<String>()

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
        if let existing = try? String(contentsOf: envFileURL, encoding: .utf8), existing == content {
            return
        }
        do {
            try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)
            try content.write(to: envFileURL, atomically: true, encoding: .utf8)
        } catch {
            Log.system.error("shell env: could not write env file: \(error.localizedDescription, privacy: .public)")
        }
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
            let target = Self.resolvedPath(expanded)
            guard var content = try? String(contentsOfFile: target, encoding: .utf8) else { continue }
            if content.contains(Self.blockStart) { continue }
            if Self.isUnsupportedShell(expanded) || Self.isUnsupportedShell(target) {
                Self.warnUnsupportedOnce(path: expanded)
                continue
            }
            let sourceLine = "[ -f \"$HOME/.config/proxy-manager/env.sh\" ] && . \"$HOME/.config/proxy-manager/env.sh\""
            let block = "\n\(Self.blockStart)\n\(sourceLine)\n\(Self.blockEnd)\n"
            content += block
            write(content, to: target)
        }
    }

    func remove(rcFiles: [String]) {
        for path in rcFiles {
            let expanded = expand(path)
            guard FileManager.default.fileExists(atPath: expanded) else { continue }
            let target = Self.resolvedPath(expanded)
            guard var content = try? String(contentsOfFile: target, encoding: .utf8) else { continue }
            var removed = false
            while let start = content.range(of: Self.blockStart),
                  let end = content.range(of: Self.blockEnd, options: [], range: start.upperBound..<content.endIndex) {
                let full = start.lowerBound..<end.upperBound
                content.removeSubrange(full)
                removed = true
            }
            // No marker block: never rewrite the file (it may hold fish/csh
            // syntax we cannot safely reproduce).
            guard removed else { continue }
            content = content.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            write(content, to: target)
        }
    }

    /// Follows symlinks (including a dangling final link) so a write updates the
    /// link target instead of replacing the link with a regular file.
    static func resolvedPath(_ path: String) -> String {
        var current = URL(fileURLWithPath: path).standardized.path
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { break }
            if destination.hasPrefix("/") {
                current = URL(fileURLWithPath: destination).standardized.path
            } else {
                current = URL(fileURLWithPath: current).deletingLastPathComponent()
                    .appendingPathComponent(destination).standardized.path
            }
        }
        return current
    }

    static func isUnsupportedShell(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return name == "config.fish" || name.hasSuffix(".fish")
            || name.hasSuffix(".csh") || name.hasSuffix(".tcsh")
    }

    private static func warnUnsupportedOnce(path: String) {
        warnedLock.lock()
        let first = warnedUnsupportedPaths.insert(path).inserted
        warnedLock.unlock()
        guard first else { return }
        Log.system.warning("shell env: skipping \(path, privacy: .public) — fish/csh syntax is not supported")
    }

    private func write(_ content: String, to path: String) {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions]
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            Log.system.error("shell env: could not write \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        // Atomic writes replace the inode; restore the original mode.
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
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
