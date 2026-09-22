import AppKit

/// Shared, cached app-icon lookup.
///
/// AppKit caches icons internally, but that is not a documented contract and the
/// dashboard feed re-renders cells at ~10 Hz, so cache here. `NSCache` is
/// thread-safe and evicts under memory pressure. Never mutate the returned
/// image's `size` — the same instance is shared across callers; scale at the
/// view instead.
enum AppIcon {
    private static let cache = NSCache<NSString, NSImage>()

    /// The app's icon, or nil when it cannot be resolved (e.g. a bundle-less
    /// process). Callers show `placeholder` in that case.
    static func image(bundleId: String?, path: String?) -> NSImage? {
        let key = (bundleId ?? path) as NSString?
        if let key, let cached = cache.object(forKey: key) { return cached }

        var image: NSImage?
        if let path, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if let bundleId, !bundleId.isEmpty,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        if let image, let key { cache.setObject(image, forKey: key) }
        return image
    }

    /// A template "no icon" symbol; tint it with the caller's color.
    static let placeholder: NSImage = {
        let image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "No icon")
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()
}
