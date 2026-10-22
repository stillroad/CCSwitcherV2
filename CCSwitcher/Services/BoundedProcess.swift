import Foundation
import Darwin

/// Drains both pipes while the child runs, with a deadline and an output cap.
/// Waiting for exit before reading can deadlock once either pipe fills.
enum BoundedProcess {
    struct Result: Sendable {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    enum Failure: LocalizedError {
        case timedOut
        case outputTooLarge

        var errorDescription: String? {
            switch self {
            case .timedOut: return "The command timed out. Try again shortly."
            case .outputTooLarge: return "The command returned unexpectedly large output."
            }
        }
    }

    static func run(executable: String, arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 15, outputLimit: Int = 1_048_576) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Swift.Result {
                    try runBlocking(executable: executable, arguments: arguments, environment: environment,
                                    timeout: timeout, outputLimit: outputLimit)
                })
            }
        }
    }

    static func runBlocking(executable: String, arguments: [String], environment: [String: String]? = nil,
                            timeout: TimeInterval = 15, outputLimit: Int = 1_048_576) throws -> Result {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        let handles = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        for handle in handles {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
        defer {
            if process.isRunning {
                process.terminate()
                // A child that ignores SIGTERM must not keep a refresh stuck.
                Thread.sleep(forTimeInterval: 0.1)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            for handle in handles { try? handle.close() }
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        try process.run()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, timeout)
        var output = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var descriptors = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        while true {
            for index in handles.indices {
                while true {
                    let count = read(handles[index].fileDescriptor, &buffer, buffer.count)
                    if count == 0 { descriptors[index].fd = -1 }
                    if count <= 0 { break }
                    guard output[0].count + output[1].count + count <= outputLimit else {
                        throw Failure.outputTooLarge
                    }
                    output[index].append(contentsOf: buffer.prefix(count))
                }
            }
            if !process.isRunning {
                // One final drain after observing exit; the last write may have
                // arrived just after the first drain above.
                for index in handles.indices {
                    while true {
                        let count = read(handles[index].fileDescriptor, &buffer, buffer.count)
                        if count <= 0 { break }
                        guard output[0].count + output[1].count + count <= outputLimit else { throw Failure.outputTooLarge }
                        output[index].append(contentsOf: buffer.prefix(count))
                    }
                }
                return Result(stdout: String(decoding: output[0], as: UTF8.self),
                              stderr: String(decoding: output[1], as: UTF8.self), status: process.terminationStatus)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timedOut }
            _ = poll(&descriptors, nfds_t(descriptors.count), 50)
        }
    }
}
