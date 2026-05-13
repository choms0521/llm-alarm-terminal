import Darwin
import Dispatch
import Foundation

/// EAGAIN-aware reader for a PTY master fd.
///
/// Driven by `DispatchIO` in stream mode so the read loop runs off the main
/// queue. On EOF the `onEOF` callback fires exactly once and the reader is
/// torn down. The caller still owns `fd` lifetime — `PTYReader` will not
/// `close()` the descriptor.
public final class PTYReader {
    private let fd: Int32
    private let queue: DispatchQueue
    private var io: DispatchIO?
    private var didFinish = false

    public init(fd: Int32, label: String = "pty.reader") {
        self.fd = fd
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Start reading. `onData` receives non-empty chunks. `onEOF` runs once
    /// when the master fd returns 0 bytes (child closed its terminal) or hits
    /// a non-recoverable error.
    public func start(
        onData: @escaping (Data) -> Void,
        onEOF: @escaping (Int32) -> Void
    ) {
        let io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in
            // Cleanup handler — DispatchIO closed its private channel state.
            // The fd itself is NOT closed because we passed PTYReader the
            // caller-owned fd; explicit close stays with the SessionManager.
        }
        io.setLimit(lowWater: 1)
        io.setLimit(highWater: 64 * 1024)
        self.io = io

        io.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, errCode in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                onData(Data(data))
            }
            if done {
                if !self.didFinish {
                    self.didFinish = true
                    onEOF(errCode)
                }
            }
        }
    }

    public func stop() {
        io?.close(flags: .stop)
        io = nil
    }
}
