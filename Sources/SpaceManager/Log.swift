import Foundation
import os

/// Unified-log channels. NSLog is useless here: on macOS 27 its message body
/// is stored as "<private>", so a trace survives only as timestamps. These
/// log at .notice (persisted to disk) and every interpolation that's needed
/// to debug is marked public. Read them with:
///
///   /usr/bin/log show --predicate 'subsystem == "com.taylorbird.spacemanager"' --last 1h
///
/// Add `AND category == "WindowMover"` (etc.) to narrow it.
enum Log {
    static let subsystem = "com.taylorbird.spacemanager"

    static let mover = Logger(subsystem: subsystem, category: "WindowMover")
    static let placer = Logger(subsystem: subsystem, category: "WindowPlacer")
    static let preview = Logger(subsystem: subsystem, category: "preview")
    static let switcher = Logger(subsystem: subsystem, category: "switcher")
    static let watchdog = Logger(subsystem: subsystem, category: "watchdog")
    static let chrome = Logger(subsystem: subsystem, category: "chrome")
    static let login = Logger(subsystem: subsystem, category: "login")
    static let setup = Logger(subsystem: subsystem, category: "setup")
}

extension CGPoint {
    /// Compact "(x, y)" for log lines.
    var logDescription: String { String(format: "(%.0f, %.0f)", x, y) }
}

extension CGRect {
    var logDescription: String {
        String(format: "(%.0f, %.0f, %.0f×%.0f)", origin.x, origin.y, size.width, size.height)
    }
}

/// Reports main-thread stalls — the spinning-wheel freezes left no trace
/// before this existed. A background timer pings the main queue; a ping that
/// takes longer than `threshold` to run is logged with its duration once the
/// main thread recovers, and a stall that's still going after `ongoing` is
/// logged while it's happening, in case it never recovers.
final class MainThreadWatchdog {
    private let queue = DispatchQueue(label: "com.taylorbird.spacemanager.watchdog",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Send time of the ping the main thread hasn't run yet (queue-confined).
    private var outstanding: DispatchTime?
    private var warnedOngoing = false

    private static let interval: TimeInterval = 0.25
    private static let threshold: TimeInterval = 0.25
    private static let ongoing: TimeInterval = 2.0

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval,
                   leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if let sent = outstanding {
            let waited = Self.seconds(since: sent)
            if waited > Self.ongoing, !warnedOngoing {
                warnedOngoing = true
                Log.watchdog.error("main thread unresponsive for \(waited, format: .fixed(precision: 1), privacy: .public)s and counting")
            }
            return
        }
        let sent = DispatchTime.now()
        outstanding = sent
        DispatchQueue.main.async { [weak self] in
            let lag = Self.seconds(since: sent)
            if lag > Self.threshold {
                Log.watchdog.error("main thread was blocked for \(lag, format: .fixed(precision: 2), privacy: .public)s")
            }
            self?.queue.async {
                self?.outstanding = nil
                self?.warnedOngoing = false
            }
        }
    }

    private static func seconds(since t: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000_000
    }
}
