import Foundation

// Crash probe: an absolute-form request with an out-of-range port must not
// terminate the process. `HTTPRequest.port` used `UInt16(p)` (non-failable),
// which traps for p > 65535.
//
// Compiled with Sources/Proxy/HTTPParser.swift. Exit code 0 = survived;
// any signal exit (e.g. 133/SIGTRAP) = crash.
let raw = Array("GET http://example.com:99999/path HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)
guard let request = HTTPParser.parse(raw) else {
    print("PROBE: parser returned nil (no crash)")
    exit(0)
}
let port = request.port
print("PROBE: port=\(port) (no crash)")
exit(0)
