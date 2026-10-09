import BitampPakProtocol
import Foundation

/// Runs a third-party Pak's program and talks to it: JSON requests, one per line, on its
/// standard input; responses, matched by id, from its standard output. Its standard error
/// goes to the log. The program starts on the first request and again after it exits,
/// unless it keeps crashing.
@MainActor
final class PakConnection {
    enum Failure: LocalizedError {
        case couldNotStart(String)
        case exited
        case keepsCrashing
        case timedOut(String)
        case unreadable(String)
        case pak(String)

        var errorDescription: String? {
            switch self {
            case .couldNotStart(let reason): return "The Pak couldn't start: \(reason)"
            case .exited: return "The Pak stopped running."
            case .keepsCrashing: return "The Pak keeps crashing, so Bitamp stopped starting it."
            case .timedOut(let method): return "The Pak took too long to answer (\(method))."
            case .unreadable(let method): return "The Pak's answer to \(method) couldn't be read."
            case .pak(let message): return message
            }
        }
    }

    nonisolated static let timeout: TimeInterval = 30
    /// More crashes than this within `crashWindow` and the program isn't started again.
    static let maxCrashes = 3
    static let crashWindow: TimeInterval = 60

    private let executable: URL
    private let name: String
    private let timeout: TimeInterval
    /// Sent first each time the program starts. Its answer goes to `onHello`.
    var hello: () -> (method: String, params: PakMethod.Hello)
    var onHello: ((PakMethod.AccountResult) -> Void)?
    /// A line the program wrote to standard error. Logged unless set (`PakCheck` shows them).
    var onLog: ((String) -> Void)?
    /// A line on standard output that isn't the answer to a request. Logged unless set.
    var onUnexpectedOutput: ((String) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    private var pending: [Int: (method: String, continuation: CheckedContinuation<Data, Error>)] = [:]
    private var crashes: [Date] = []
    /// The shutdown request, whose answer nothing waits for.
    private var shutdownID: Int?
    /// Set while the program is starting, so concurrent requests wait for the same hello.
    private var starting: Task<Void, Error>?

    init(executable: URL, name: String, timeout: TimeInterval = PakConnection.timeout,
         hello: @escaping () -> (method: String, params: PakMethod.Hello)) {
        self.executable = executable
        self.name = name
        self.timeout = timeout
        self.hello = hello
    }

    var isRunning: Bool { process?.isRunning ?? false }

    /// Sends a request, starting the program first if needed, and decodes its result.
    func request<Params: Codable, Result: Codable>(
        _ method: String, _ params: Params, as result: Result.Type
    ) async throws -> Result {
        try await ensureStarted()
        return try await send(method, params, as: result)
    }

    /// Asks the program to finish, and makes sure it does.
    func shutdown() {
        guard let process, process.isRunning else { return }
        let id = nextID
        nextID += 1
        shutdownID = id
        write(PakRequest(id: id, method: PakMethod.shutdown, params: PakMethod.Empty()))
        // A program that ignores the request goes anyway, a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
    }

    // MARK: - Starting

    private func ensureStarted() async throws {
        if isRunning, starting == nil { return }
        if let starting { return try await starting.value }
        let task = Task { try await start() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func start() async throws {
        crashes = crashes.filter { $0.timeIntervalSinceNow > -Self.crashWindow }
        guard crashes.count < Self.maxCrashes else { throw Failure.keepsCrashing }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        // A Pak that exits before reading its input would otherwise kill Bitamp with SIGPIPE
        // on the next write; this way the write just fails.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let lines = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty means the program closed its output; stop listening or this repeats forever.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in lines.append(data) {
                Task { @MainActor in self?.received(line) }
            }
        }
        let logLines = LineBuffer()
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in logLines.append(data) {
                Task { @MainActor in self?.logged(String(decoding: line, as: UTF8.self)) }
            }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus, reason = ended.terminationReason
            Task { @MainActor in self?.exited(ended, status: status, uncaught: reason == .uncaughtSignal) }
        }
        do {
            try process.run()
        } catch {
            throw Failure.couldNotStart(error.localizedDescription)
        }
        self.process = process
        input = stdin.fileHandleForWriting

        let (method, params) = hello()
        let account = try await send(method, params, as: PakMethod.AccountResult.self)
        onHello?(account)
    }

    private func exited(_ ended: Process, status: Int32, uncaught: Bool) {
        guard ended === process else { return }
        process = nil
        input = nil
        if uncaught || status != 0 {
            crashes.append(Date())
            NSLog("Bitamp: \(name) Pak exited with status \(status)")
        }
        let waiting = pending
        pending = [:]
        for (_, request) in waiting { request.continuation.resume(throwing: Failure.exited) }
    }

    // MARK: - Messages

    private func send<Params: Codable, Result: Codable>(
        _ method: String, _ params: Params, as result: Result.Type
    ) async throws -> Result {
        guard isRunning else { throw Failure.exited }
        let id = nextID
        nextID += 1
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = (method, continuation)
            write(PakRequest(id: id, method: method, params: params))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let request = self?.pending.removeValue(forKey: id) else { return }
                    request.continuation.resume(throwing: Failure.timedOut(method))
                }
            }
        }
        guard let response = try? JSONDecoder().decode(PakResponse<Result>.self, from: data) else {
            throw Failure.unreadable(method)
        }
        if let error = response.error { throw Failure.pak(error.message) }
        guard let value = response.result else { throw Failure.unreadable(method) }
        return value
    }

    private func write<Params: Codable>(_ request: PakRequest<Params>) {
        guard var data = try? JSONEncoder().encode(request) else { return }
        data.append(0x0A)
        do {
            try input?.write(contentsOf: data)
        } catch {
            NSLog("Bitamp: couldn't write to the \(name) Pak: \(error)")
        }
    }

    private func received(_ line: Data) {
        let header = try? JSONDecoder().decode(ResponseID.self, from: line)
        if let header, header.id == shutdownID { return }
        guard let header, let request = pending.removeValue(forKey: header.id) else {
            let text = String(decoding: line, as: UTF8.self)
            if let onUnexpectedOutput { onUnexpectedOutput(text) } else { NSLog("Bitamp: %@ Pak said something unexpected: %@", name, text) }
            return
        }
        request.continuation.resume(returning: line)
    }

    private func logged(_ line: String) {
        if let onLog { onLog(line) } else { NSLog("Bitamp: %@ Pak: %@", name, line) }
    }

    private struct ResponseID: Decodable {
        let id: Int
    }
}

/// Splits a byte stream into lines, keeping a partial last line for the next chunk.
/// Used from one reading queue at a time, as `readabilityHandler` calls it.
private final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()

    func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
