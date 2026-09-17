import CoreGraphics
import Foundation

// Usage: window-id <pid> <minWidth> [timeoutSeconds]
// Prints the CGWindowID of the first on-screen window owned by <pid> whose
// width is at least <minWidth>. Used to target `screencapture -l`.
let args = CommandLine.arguments
guard args.count >= 3, let pid = Int(args[1]), let minWidth = Double(args[2]) else {
    FileHandle.standardError.write("usage: window-id <pid> <minWidth> [timeout]\n".data(using: .utf8)!)
    exit(2)
}
let timeout = args.count > 3 ? (Double(args[3]) ?? 15) : 15
let deadline = Date().addingTimeInterval(timeout)

while Date() < deadline {
    if let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? Int) == pid else { continue }
            let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = bounds["Width"] as? Double ?? 0
            if width >= minWidth {
                print(info[kCGWindowNumber as String] as? Int ?? -1)
                exit(0)
            }
        }
    }
    usleep(200_000)
}
FileHandle.standardError.write("window-id: no window for pid \(pid) after \(timeout)s\n".data(using: .utf8)!)
exit(1)
