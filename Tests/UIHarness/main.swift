import AppKit

// Standalone regression harness for the UI truncation-tooltip logic.
//
// Build + run (see Tests/run-all.sh):
//   xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
//     -framework AppKit \
//     Sources/UI/TruncationDetector.swift \
//     Tests/UIHarness/main.swift -o /tmp/uiharness && /tmp/uiharness
//
// `TruncatableText` (SwiftUI) and the AppKit feed cells both delegate the
// "is this ellipsised?" decision to `TruncationDetector`, so this is where the
// boundary behavior is pinned down.

var failures = 0
var checks = 0

func check(_ name: String, _ condition: Bool) {
    checks += 1
    if condition {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)")
    }
}

let font = NSFont.systemFont(ofSize: 13)

print("== Single-line truncation ==")
check("fits with room", !TruncationDetector.isTruncated(requiredWidth: 100, availableWidth: 200))
check("overflows", TruncationDetector.isTruncated(requiredWidth: 200, availableWidth: 100))
check("exact fit is not truncated", !TruncationDetector.isTruncated(requiredWidth: 100, availableWidth: 100))
check("sub-epsilon overflow is not truncated",
      !TruncationDetector.isTruncated(requiredWidth: 100.4, availableWidth: 100))
check("just over epsilon is truncated",
      TruncationDetector.isTruncated(requiredWidth: 100.6, availableWidth: 100))
check("zero required is never truncated",
      !TruncationDetector.isTruncated(requiredWidth: 0, availableWidth: 100))
check("zero available is never truncated (unmeasured)",
      !TruncationDetector.isTruncated(requiredWidth: 100, availableWidth: 0))

print("== Multi-line truncation ==")
check("wrapped text fits", !TruncationDetector.isTruncated(requiredHeight: 30, availableHeight: 40))
check("wrapped text clipped", TruncationDetector.isTruncated(requiredHeight: 60, availableHeight: 40))
check("exact wrapped height is not truncated",
      !TruncationDetector.isTruncated(requiredHeight: 40, availableHeight: 40))
check("zero available height is never truncated",
      !TruncationDetector.isTruncated(requiredHeight: 40, availableHeight: 0))

print("== Required width ==")
check("empty string has zero width", TruncationDetector.requiredWidth(of: "", font: font) == 0)
check("non-empty string has positive width", TruncationDetector.requiredWidth(of: "example.com", font: font) > 0)
check("longer string is wider",
      TruncationDetector.requiredWidth(of: "api.deepseek.com", font: font)
        > TruncationDetector.requiredWidth(of: "api.", font: font))

print("== Tooltip decision ==")
let short = "short"
let long = "a-very-long-application-name-that-will-not-fit"
let shortWidth = TruncationDetector.requiredWidth(of: short, font: font)
let longWidth = TruncationDetector.requiredWidth(of: long, font: font)
check("empty text yields no tooltip",
      TruncationDetector.tooltip(text: "", availableWidth: 500, font: font) == nil)
check("fitting text yields no tooltip",
      TruncationDetector.tooltip(text: short, availableWidth: shortWidth, font: font) == nil)
check("fitting text with room yields no tooltip",
      TruncationDetector.tooltip(text: short, availableWidth: 500, font: font) == nil)
check("clipped text yields the full value",
      TruncationDetector.tooltip(text: long, availableWidth: longWidth - 40, font: font) == long)
check("one point short is not clipped",
      TruncationDetector.tooltip(text: long, availableWidth: longWidth, font: font) == nil)

func uuid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

// Applies a diff the way NSTableView does: removals descending, insertions
// ascending. The result must equal the new snapshot.
func apply(_ diff: FeedTableDiff, old: [UUID], new: [UUID]) -> [UUID] {
    var result = old
    for index in diff.removed.reversed() { result.remove(at: index) }
    for index in diff.inserted { result.insert(new[index], at: index) }
    return result
}

func checkDiff(_ name: String, old: [UUID], new: [UUID],
               removed: [Int], inserted: [Int]) {
    guard let diff = FeedTableDiff.compute(old: old, new: new) else {
        check("\(name): diff exists", false)
        return
    }
    check("\(name): removed \(removed)", Array(diff.removed) == removed)
    check("\(name): inserted \(inserted)", Array(diff.inserted) == inserted)
    check("\(name): applies to new", apply(diff, old: old, new: new) == new)
    check("\(name): removals descending", Array(diff.removed.reversed())
            == Array(diff.removed).sorted(by: >))
    check("\(name): insertions ascending", Array(diff.inserted)
            == Array(diff.inserted).sorted())
}

print("== Feed table diff ==")
let a = uuid(1), b = uuid(2), c = uuid(3), d = uuid(4), x = uuid(5), y = uuid(6)

checkDiff("insert at top", old: [a, b, c], new: [x, a, b, c],
          removed: [], inserted: [0])
checkDiff("remove at bottom", old: [a, b, c], new: [a, b],
          removed: [2], inserted: [])
checkDiff("insert and remove", old: [a, b, c], new: [x, a, c],
          removed: [1], inserted: [0])
checkDiff("insert and remove many", old: [a, b, c, d], new: [x, a, c, y],
          removed: [1, 3], inserted: [0, 3])
checkDiff("empty to non-empty", old: [], new: [a, b],
          removed: [], inserted: [0, 1])
checkDiff("non-empty to empty", old: [a, b], new: [],
          removed: [0, 1], inserted: [])
checkDiff("no common rows", old: [a, b], new: [x, y],
          removed: [0, 1], inserted: [0, 1])

check("reordered common ids falls back to reloadData",
      FeedTableDiff.compute(old: [a, b, c], new: [c, b, a]) == nil)
check("identical ids has no diff",
      FeedTableDiff.compute(old: [a, b, c], new: [a, b, c]) == nil)
check("identical empty has no diff",
      FeedTableDiff.compute(old: [], new: []) == nil)
check("partially reordered common ids falls back to reloadData",
      FeedTableDiff.compute(old: [a, b, c], new: [b, a, c]) == nil)

print("== App icon cache ==")
let defaultResolver = AppIcon.resolver

var missCount = 0
AppIcon.resolver = { _, _ in
    missCount += 1
    return nil
}
AppIcon.clearCachesForTesting()

check("missing icon resolves to nil", AppIcon.image(bundleId: "missing", path: nil) == nil)
check("repeated missing icon stays nil", AppIcon.image(bundleId: "missing", path: nil) == nil)
check("negative cache calls the resolver once", missCount == 1)

_ = AppIcon.image(bundleId: "missing-2", path: nil)
check("a different id resolves separately", missCount == 2)

_ = AppIcon.image(bundleId: "missing", path: nil)
check("a negative hit skips the resolver", missCount == 2)

AppIcon.clearCachesForTesting()
_ = AppIcon.image(bundleId: "missing", path: nil)
check("clearing caches allows a new resolution", missCount == 3)

var hitCount = 0
let testIcon = NSImage(size: NSSize(width: 16, height: 16))
AppIcon.resolver = { _, _ in
    hitCount += 1
    return testIcon
}
AppIcon.clearCachesForTesting()

check("resolved icon is returned", AppIcon.image(bundleId: "present", path: nil) === testIcon)
check("second lookup returns the cached icon",
      AppIcon.image(bundleId: "present", path: nil) === testIcon)
check("positive cache calls the resolver once", hitCount == 1)

AppIcon.resolver = defaultResolver
AppIcon.clearCachesForTesting()

print("== Tooltip metrics ==")
let tooltipFont = NSFont.systemFont(ofSize: 10)
let longTip = String(repeating: "a-very-long-application-name ", count: 8)
let tipMaxWidth: CGFloat = 100
let emptyTip = TooltipMetrics.size(text: "", font: tooltipFont, maxWidth: 268)
let shortTip = TooltipMetrics.size(text: "short", font: tooltipFont, maxWidth: 268)
let wrappedTip = TooltipMetrics.size(text: longTip, font: tooltipFont, maxWidth: tipMaxWidth)

check("empty text measures non-negative",
      emptyTip.width >= 0 && emptyTip.height >= 0)
check("short text measures non-negative", shortTip.width > 0 && shortTip.height > 0)
check("short text fits within the max width", shortTip.width <= 268)
check("long text wraps within the max width", wrappedTip.width <= tipMaxWidth)
check("long text is wider than a single short line", wrappedTip.width > shortTip.width)
check("long text is taller than one line", wrappedTip.height > shortTip.height)
check("long text wraps onto several lines", wrappedTip.height >= shortTip.height * 3)
check("an unbreakable word never exceeds the max width",
      TooltipMetrics.size(text: String(repeating: "x", count: 400),
                          font: tooltipFont, maxWidth: 60).width <= 60)
check("the label font affects the measured height",
      TooltipMetrics.size(text: "short", font: NSFont.systemFont(ofSize: 20), maxWidth: 268).height
        > shortTip.height)
check("zero max width measures to zero",
      TooltipMetrics.size(text: "short", font: tooltipFont, maxWidth: 0) == .zero)

print("")
print("== SUMMARY: \(checks - failures)/\(checks) passed ==")
exit(failures == 0 ? 0 : 1)
