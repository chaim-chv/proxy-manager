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

print("")
print("== SUMMARY: \(checks - failures)/\(checks) passed ==")
exit(failures == 0 ? 0 : 1)
