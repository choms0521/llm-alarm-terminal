import Foundation

/// Ties the input and output halves of a session together.
///
/// Input: WS input -> `SerialInputQueue` -> origin sink (R8). Output (`.external`
/// only): master fd -> `PTYReader` -> `Utf8StreamAccumulator` -> kind=output
/// envelopes. `.internal` output is unsupported in P4 (C4) and surfaces
/// INTERNAL_OUTPUT_UNSUPPORTED.
public actor SessionDaemon {
    private let inputQueue = SerialInputQueue()
    private var outputTaps: [UUID: OutputTap] = [:]
    private let deviceActor = EnvelopeActor(deviceId: "daemon-local")

    public init() {}

    // MARK: - Input

    public func attachInput(sessionId: UUID, sink: InputSink) async {
        await inputQueue.attach(sessionId: sessionId, sink: sink)
    }

    public func sendInput(_ item: InputItem, to sessionId: UUID) async {
        await inputQueue.enqueue(item, for: sessionId)
    }

    // MARK: - Output

    /// Taps an `.external` session's master fd and emits reassembled, complete
    /// UTF-8 as kind=output envelopes. A second attach for the same session is a
    /// no-op.
    public func attachExternalOutput(
        sessionId: UUID,
        masterFD: Int32,
        emit: @escaping @Sendable (WSEnvelope) -> Void,
        onClosed: @escaping @Sendable () -> Void = {}
    ) {
        guard outputTaps[sessionId] == nil else { return }
        let tap = OutputTap(masterFD: masterFD, actor: deviceActor, emit: emit, onClosed: onClosed)
        outputTaps[sessionId] = tap
        tap.start()
    }

    /// `.internal` byte-faithful output is unsupported in P4 (C4): surface the
    /// signal so the limitation is never mistaken for a silent failure.
    public func requestInternalOutput(
        sessionId: UUID,
        emit: @escaping @Sendable (WSEnvelope) -> Void
    ) {
        emit(WSEnvelope(
            seq: 0,
            actor: deviceActor,
            kind: .error,
            code: DaemonErrorCode.internalOutputUnsupported.rawValue,
            text: #"{"message":"internal output stream unsupported in P4"}"#
        ))
    }

    public func detach(sessionId: UUID) async {
        outputTaps[sessionId]?.stop()
        outputTaps[sessionId] = nil
        await inputQueue.detach(sessionId: sessionId)
    }
}

/// Output reader for one `.external` session. The accumulator and seq are touched
/// only inside `PTYReader`'s serial onData callback, so no extra locking is
/// needed; `@unchecked Sendable` documents that invariant.
final class OutputTap: @unchecked Sendable {
    private let reader: PTYReader
    private let actor: EnvelopeActor
    private let emit: @Sendable (WSEnvelope) -> Void
    private let onClosed: @Sendable () -> Void
    private var accumulator = Utf8StreamAccumulator()
    private var seq: UInt64 = 0

    init(
        masterFD: Int32,
        actor: EnvelopeActor,
        emit: @escaping @Sendable (WSEnvelope) -> Void,
        onClosed: @escaping @Sendable () -> Void = {}
    ) {
        self.reader = PTYReader(fd: masterFD)
        self.actor = actor
        self.emit = emit
        self.onClosed = onClosed
    }

    func start() {
        reader.start(
            onData: { [weak self] data in
                guard let self else { return }
                if let text = self.accumulator.push(data) {
                    self.seq += 1
                    self.emit(WSEnvelope(seq: self.seq, actor: self.actor, kind: .output, text: text))
                }
            },
            onEOF: { [weak self] _ in self?.onClosed() }
        )
    }

    func stop() {
        reader.stop()
    }
}
