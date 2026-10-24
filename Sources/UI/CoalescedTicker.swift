import Foundation
import Combine

/// A `RunLoop` timer with tolerance, so App Nap can coalesce its wakeups while
/// nothing on screen needs the tick. `tick` increments on the main run loop;
/// owners start it only while their window is visible and stop it otherwise.
final class CoalescedTicker: ObservableObject {
    @Published private(set) var tick = 0

    private let interval: TimeInterval
    private var timer: Timer?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick &+= 1
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
