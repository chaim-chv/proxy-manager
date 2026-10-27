import AppKit

/// Delivers `proxymanager://` URLs to the router.
///
/// Custom URL schemes arrive as `kAEGetURL` Apple events. The handler is
/// installed before the app finishes launching and buffers events until
/// `AppModel` and the integration coordinator are ready, so a cold launch from
/// `open proxymanager://…` behaves exactly like a warm one.
///
/// Receiving an Apple event needs no TCC permission; sending one does.
final class URLSchemeHandler: NSObject {
    static let shared = URLSchemeHandler()

    private var pending: [URL] = []
    private var ready = false
    private let maxPending = 16

    func install() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor,
                                      withReplyEvent reply: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: value) else {
            Log.integration.notice("url: could not read the URL from the Apple event")
            return
        }
        enqueue(url)
    }

    func enqueue(_ url: URL) {
        guard ready else {
            if pending.count < maxPending { pending.append(url) }
            return
        }
        perform(url)
    }

    func markReady() {
        guard !ready else { return }
        ready = true
        let queued = pending
        pending = []
        for url in queued { perform(url) }
    }

    private func perform(_ url: URL) {
        switch URLCommandParser.parse(url) {
        case .failure(let error):
            Log.integration.notice("url: rejected: \(String(describing: error), privacy: .public)")
        case .success(let command):
            guard let result = AppModel.shared.integration.performURL(command) else {
                Log.integration.notice("url: ignored; external control is off")
                return
            }
            if result.ok {
                Log.integration.debug("url: \(command.action, privacy: .public) ok")
            } else {
                Log.integration.notice("url: \(command.action, privacy: .public) failed \(result.error?.code.rawValue ?? "?", privacy: .public)")
            }
        }
    }
}
