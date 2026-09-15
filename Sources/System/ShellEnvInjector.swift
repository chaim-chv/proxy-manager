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
        var noProxy = "127.0.0.1,localhost,::1"
        let t = tunnelHost.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty && t != "127.0.0.1" && t != "localhost" {
            noProxy += ",\(t)"
        }
        let content = """
        # Managed by Proxy Manager — do not edit by hand.
        export HTTP_PROXY="http://\(bindHost):\(port)"
        export HTTPS_PROXY="http://\(bindHost):\(port)"
        export NO_PROXY="\(noProxy)"
        export PROXY_MANAGER_ACTIVE="1"
        """
        try? FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)
        try? content.write(to: envFileURL, atomically: true, encoding: .utf8)
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
