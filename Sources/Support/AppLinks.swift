import Foundation

/// Canonical external links, surfaced in Settings → About and the standard
/// About panel.
enum AppLinks {
    static let homepage = URL(string: "https://proxy-manager.chv.ovh/")!
    static let source = URL(string: "https://github.com/chaim-chv/proxy-manager")!
    static let integrationDocs = URL(string: "https://proxy-manager.chv.ovh/docs/integration.html")!
}
