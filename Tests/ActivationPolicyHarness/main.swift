import AppKit

// Standalone harness for ActivationPolicy (see Tests/run-all.sh).
//
// The regression it pins: `NSApp.setActivationPolicy` transforms the process
// even when the policy does not change, and that transform deactivates the app.
// A redundant `.accessory` while opening a window therefore hid the Dock icon
// and left the new window behind the previously active app.

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

print("== Activation policy decision ==")

check("menu bar only with no window is accessory",
      ActivationPolicy.policy(iconMode: .menuBarOnly, hasOpenWindow: false) == .accessory)
check("menu bar only with an open window is regular",
      ActivationPolicy.policy(iconMode: .menuBarOnly, hasOpenWindow: true) == .regular)
check("menu bar + Dock is always regular",
      ActivationPolicy.policy(iconMode: .menuBarAndDock, hasOpenWindow: false) == .regular
      && ActivationPolicy.policy(iconMode: .menuBarAndDock, hasOpenWindow: true) == .regular)
check("Dock only is always regular",
      ActivationPolicy.policy(iconMode: .dockOnly, hasOpenWindow: false) == .regular
      && ActivationPolicy.policy(iconMode: .dockOnly, hasOpenWindow: true) == .regular)

print("== Activation policy application ==")

_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
check("an unchanged policy does not transform", ActivationPolicy.apply(.accessory) == false)
check("policy stays accessory", NSApp.activationPolicy() == .accessory)

check("a real change transforms", ActivationPolicy.apply(.regular) == true)
check("policy is regular", NSApp.activationPolicy() == .regular)
check("re-applying the same policy does not transform", ActivationPolicy.apply(.regular) == false)
check("a change back transforms", ActivationPolicy.apply(.accessory) == true)
check("policy is accessory again", NSApp.activationPolicy() == .accessory)

print("")
if failures == 0 {
    print("PASS: activation policy (\(checks) checks)")
    exit(0)
} else {
    print("FAIL: activation policy (\(failures)/\(checks) checks failed)")
    exit(1)
}
