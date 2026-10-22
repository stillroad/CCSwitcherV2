import Foundation

enum LocalStatsError: Error, LocalizedError {
    case timeLimit, recordTooLarge, historyUnavailable, historyChanged

    var errorDescription: String? {
        switch self {
        case .timeLimit:
            return "Stopped after one minute: local history is too large to calculate quickly. Previous statistics were kept."
        case .recordTooLarge:
            return "Stopped because a session log contains an unusually large record. Previous statistics were kept."
        case .historyUnavailable:
            return "Could not read local session history. Previous statistics were kept."
        case .historyChanged:
            return "A session log changed during calculation. Previous statistics were kept; you can try again."
        }
    }
}

/// A monotonic, cooperative deadline shared by reading, parsing and aggregation.
/// Checking only between files is insufficient: a single session can be several GB.
struct LocalStatsBudget: Sendable {
    private let deadline: ContinuousClock.Instant

    init(seconds: TimeInterval = 60) {
        deadline = .now.advanced(by: .seconds(seconds))
    }

    func check() throws {
        try Task.checkCancellation()
        if ContinuousClock.now >= deadline { throw LocalStatsError.timeLimit }
    }
}

typealias LocalStatsProgress = @Sendable (String) -> Void

protocol LocalStatsCalculating: Sendable {
    func calculate(budget: LocalStatsBudget, progress: @escaping LocalStatsProgress) async throws -> LocalStatsSnapshot
}

struct LocalStatsCalculator: LocalStatsCalculating {
    let cache: SessionParseCacheV2

    init(cache: SessionParseCacheV2 = .shared) { self.cache = cache }

    func calculate(budget: LocalStatsBudget, progress: @escaping LocalStatsProgress) async throws -> LocalStatsSnapshot {
        do {
            try await cache.refreshFromFilesystem(budget: budget, progress: progress)
            progress("Adding up costs…")
            let cost = try await cache.costSummary(budget: budget)
            let activity = await cache.activityStatsToday()
            try budget.check()
            let snapshot = LocalStatsSnapshot(updatedAt: Date(), cost: cost, activity: activity)
            await cache.releaseMemory()
            return snapshot
        } catch {
            await cache.releaseMemory()
            throw error
        }
    }
}

/// Reads a fixed snapshot of the file in small chunks. Never copies a whole
/// multi-GB log into Data and String, or follows a continuously growing file.
enum JSONLReader {
    static func forEachLine(at url: URL, budget: LocalStatsBudget,
                            chunkSize: Int = 64 * 1024, maxLineBytes: Int = 8 * 1024 * 1024,
                            body: (Data) throws -> Void) throws {
        try budget.check()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var remaining = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        var line = Data()
        while remaining > 0 {
            try budget.check()
            guard let chunk = try handle.read(upToCount: Int(min(UInt64(chunkSize), remaining))),
                  !chunk.isEmpty else { throw LocalStatsError.historyChanged }
            remaining -= UInt64(chunk.count)
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                try budget.check()
                let newline = chunk[cursor...].firstIndex(of: 0x0A)
                let end = newline ?? chunk.endIndex
                guard line.count + end - cursor <= maxLineBytes else { throw LocalStatsError.recordTooLarge }
                line.append(chunk[cursor..<end])
                if let newline {
                    if !line.isEmpty { try autoreleasepool { try body(line) } }
                    line.removeAll(keepingCapacity: true)
                    cursor = newline + 1
                } else {
                    cursor = chunk.endIndex
                }
            }
        }
        try budget.check()
        if !line.isEmpty { try autoreleasepool { try body(line) } }
        try budget.check()
    }
}
