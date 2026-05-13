import AppKit
import os

/// Subscribes to `NSWorkspace` sleep/wake notifications.
///
/// Day 7 scope: in P1 the observer only logs — actual lifecycle reactions
/// (e.g. WS attached state -> not attached on sleep, push fallback) belong to
/// P4+ phases. The hook points are wired now so later phases can extend the
/// closures without re-plumbing notification subscriptions.
public final class PowerEventObserver {
    private static let logger = Logger(
        subsystem: "com.choms0521.ClaudeAlarmTerminal",
        category: "PowerEventObserver"
    )

    private let willSleepHandler: () -> Void
    private let didWakeHandler: () -> Void
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?

    public init(
        willSleep: @escaping () -> Void = {},
        didWake: @escaping () -> Void = {}
    ) {
        self.willSleepHandler = willSleep
        self.didWakeHandler = didWake
    }

    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        willSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Self.logger.info("NSWorkspace.willSleep")
            self?.willSleepHandler()
        }
        didWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Self.logger.info("NSWorkspace.didWake")
            self?.didWakeHandler()
        }
        Self.logger.info("PowerEventObserver started")
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let obs = willSleepObserver { center.removeObserver(obs) }
        if let obs = didWakeObserver { center.removeObserver(obs) }
        willSleepObserver = nil
        didWakeObserver = nil
    }

    deinit { stop() }
}
