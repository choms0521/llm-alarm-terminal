import Foundation

/// One unit of input bound for a session's PTY.
public struct InputItem: Sendable, Equatable {
    public let bytes: [UInt8]
    /// True if the payload is a control byte (< 0x20). `.internal` sinks cannot
    /// inject control input (C1) and surface INTERNAL_CONTROL_INPUT_UNSUPPORTED.
    public let isControl: Bool

    public init(bytes: [UInt8], isControl: Bool = false) {
        self.bytes = bytes
        self.isControl = isControl
    }
}

/// Origin-specific write target for the serial input queue. The queue's single
/// consumer awaits each `write` before the next, so a sink never sees concurrent
/// calls for the same session (R8).
public protocol InputSink: Sendable {
    func write(_ item: InputItem) async
}

/// `.external` sink: writes raw bytes to the session's master fd via the shared
/// full-write+EAGAIN path (`PTYWriter.write`), so a single Darwin.write short
/// write can never drop bytes. A hard failure surfaces PTY_WRITE_FAILED rather
/// than dropping silently.
public actor ExternalSink: InputSink {
    private let masterFD: Int32
    private let onError: @Sendable (DaemonErrorCode) -> Void

    public init(masterFD: Int32, onError: @escaping @Sendable (DaemonErrorCode) -> Void = { _ in }) {
        self.masterFD = masterFD
        self.onError = onError
    }

    public func write(_ item: InputItem) async {
        do {
            try PTYWriter.write(masterFD, Data(item.bytes))
        } catch {
            onError(.ptyWriteFailed)
        }
    }
}

/// Injects printable bytes into a libghostty surface on the main actor.
///
/// The concrete ghostty call (`ghostty_surface_text`) is provided by the app
/// layer (Day 5 wiring) through this protocol, so `InternalSink` — and the
/// daemon test target — stay free of the GhosttyKit dependency.
public protocol PrintableTextInjecting: Sendable {
    @MainActor func injectPrintable(_ bytes: [UInt8])
}

/// `.internal` sink: injects printable input on the main actor. Control bytes
/// are unsupported (C1) and surface INTERNAL_CONTROL_INPUT_UNSUPPORTED.
public final class InternalSink: InputSink, @unchecked Sendable {
    private let injector: any PrintableTextInjecting
    private let onUnsupported: @Sendable (DaemonErrorCode) -> Void

    public init(
        injector: any PrintableTextInjecting,
        onUnsupported: @escaping @Sendable (DaemonErrorCode) -> Void = { _ in }
    ) {
        self.injector = injector
        self.onUnsupported = onUnsupported
    }

    public func write(_ item: InputItem) async {
        if item.isControl {
            onUnsupported(.internalControlInputUnsupported)
            return
        }
        let injector = self.injector
        let bytes = item.bytes
        await MainActor.run { injector.injectPrintable(bytes) }
    }
}
