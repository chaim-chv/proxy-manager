import AppKit

/// Shared, cached app-icon lookup.
///
/// AppKit caches icons internally, but that is not a documented contract and the
/// dashboard feed re-renders cells at ~10 Hz, so cache here. `NSCache` is
/// thread-safe and evicts under memory pressure. Never mutate the returned
/// image's `size` — the same instance is shared across callers; scale at the
/// view instead.
enum AppIcon {
    private static let positiveCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    /// Unresolved lookups are cached too: an uninstalled/relocated app would
    /// otherwise re-query LaunchServices on the main thread for every visible
    /// cell, every tick.
    private static let negativeCache: NSCache<NSString, NSDate> = {
        let cache = NSCache<NSString, NSDate>()
        cache.countLimit = 1024
        return cache
    }()

    private static let negativeTTL: TimeInterval = 300

    /// Test seam; production never reassigns it.
    static var resolver: (String?, String?) -> NSImage? = { bundleId, path in
        if let path, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        } else if let bundleId, !bundleId.isEmpty,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    /// The app's icon, or nil when it cannot be resolved (e.g. a bundle-less
    /// process). Callers show `placeholder` in that case.
    static func image(bundleId: String?, path: String?) -> NSImage? {
        guard let key = (bundleId ?? path) as NSString? else {
            return resolver(bundleId, path)
        }

        if let cached = positiveCache.object(forKey: key) { return cached }

        if let expiry = negativeCache.object(forKey: key) {
            if expiry.timeIntervalSinceNow > 0 { return nil }
            negativeCache.removeObject(forKey: key)
        }

        if let image = resolver(bundleId, path) {
            positiveCache.setObject(image, forKey: key, cost: byteCost(of: image))
            return image
        }

        negativeCache.setObject(NSDate(timeIntervalSinceNow: negativeTTL), forKey: key)
        return nil
    }

    static func clearCachesForTesting() {
        positiveCache.removeAllObjects()
        negativeCache.removeAllObjects()
    }

    private static func byteCost(of image: NSImage) -> Int {
        if let representation = image.representations.first,
           representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            return representation.pixelsWide * representation.pixelsHigh * 4
        }
        return max(1, Int(image.size.width * image.size.height) * 4)
    }

    /// A template "no icon" symbol; tint it with the caller's color.
    static let placeholder: NSImage = {
        let image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "No icon")
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()
}
