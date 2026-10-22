import XCTest
@testable import CCSwitcherPolicy

final class LocalStatsTests: XCTestCase, @unchecked Sendable {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CCSwitcherStatsTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testChunkedReaderHandlesUTF8CRLFAndFinalLineWithoutNewline() throws {
        let file = try temporaryDirectory().appendingPathComponent("history.jsonl")
        try Data("first\r\n\n\u{1F680} café\nlast".utf8).write(to: file)
        var lines: [String] = []
        try JSONLReader.forEachLine(at: file, budget: .init(), chunkSize: 3) {
            lines.append(String(decoding: $0, as: UTF8.self))
        }
        XCTAssertEqual(lines, ["first\r", "\u{1F680} café", "last"])
    }

    func testGrowingFileStopsAtItsOriginalSize() throws {
        let file = try temporaryDirectory().appendingPathComponent("growing.jsonl")
        try Data("one\ntwo\n".utf8).write(to: file)
        var lines = 0
        try JSONLReader.forEachLine(at: file, budget: .init(), chunkSize: 4) { _ in
            lines += 1
            let writer = try FileHandle(forWritingTo: file)
            defer { try? writer.close() }
            try writer.seekToEnd()
            try writer.write(contentsOf: Data("appended\n".utf8))
        }
        XCTAssertEqual(lines, 2)
    }

    func testTruncatedFileDoesNotBecomeACompleteSnapshot() throws {
        let file = try temporaryDirectory().appendingPathComponent("truncated.jsonl")
        try Data("one\ntwo\n".utf8).write(to: file)
        XCTAssertThrowsError(try JSONLReader.forEachLine(at: file, budget: .init(), chunkSize: 4) { _ in
            let writer = try FileHandle(forWritingTo: file)
            defer { try? writer.close() }
            try writer.truncate(atOffset: 0)
        }) { error in
            guard case LocalStatsError.historyChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testFourGBSparseFileDoesNotGetLoadedIntoMemory() throws {
        let file = try temporaryDirectory().appendingPathComponent("large.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: 4 * 1024 * 1024 * 1024)
        try writer.close()
        var visited = 0
        XCTAssertThrowsError(try JSONLReader.forEachLine(at: file, budget: .init(), maxLineBytes: 1024 * 1024) { _ in
            visited += 1
        }) { error in
            guard case LocalStatsError.recordTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(visited, 0)
    }

    func testDeadlineIsCheckedWithinASingleFile() throws {
        let file = try temporaryDirectory().appendingPathComponent("slow.jsonl")
        try Data(String(repeating: "row\n", count: 100).utf8).write(to: file)
        var visited = 0
        XCTAssertThrowsError(try JSONLReader.forEachLine(at: file, budget: .init(seconds: 0.03)) { _ in
            visited += 1
            Thread.sleep(forTimeInterval: 0.01)
        }) { error in
            guard case LocalStatsError.timeLimit = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertGreaterThan(visited, 0)
        XCTAssertLessThan(visited, 100)
    }

    func testCancellationIsCheckedWithinASingleFile() async throws {
        let file = try temporaryDirectory().appendingPathComponent("cancel.jsonl")
        try Data("one\ntwo\nthree\n".utf8).write(to: file)
        let task = Task {
            var visited = 0
            do {
                try JSONLReader.forEachLine(at: file, budget: .init()) { _ in
                    visited += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                XCTFail("Cancellation must stop the reader")
            } catch is CancellationError {
                XCTAssertEqual(visited, 1)
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        await task.value
    }

    private func row(output: Int, message: String? = "message", request: String? = "request") throws -> Data {
        var msg: [String: Any] = ["model": "claude-sonnet-4-6", "usage": ["input_tokens": 10, "output_tokens": output],
                                  "content": [["type": "text", "text": "synthetic fixture"]]]
        if let message { msg["id"] = message }
        var row: [String: Any] = ["type": "assistant", "version": "2.0.0", "timestamp": "2026-10-22T12:00:00.000Z",
                                 "sessionId": "session", "message": msg]
        if let request { row["requestId"] = request }
        return try JSONSerialization.data(withJSONObject: row) + Data([0x0A])
    }

    func testStreamingParserPreservesDedupAndUnidentifiedEntries() async throws {
        let root = try temporaryDirectory()
        let projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try (row(output: 20) + row(output: 40) + row(output: 2, message: nil)).write(to: projects.appendingPathComponent("one.jsonl"))
        try (row(output: 30) + row(output: 3, request: nil)).write(to: projects.appendingPathComponent("two.jsonl"))
        let cache = SessionParseCacheV2(projectsDirectory: projects, cacheURL: root.appendingPathComponent("cache.json"), refreshPricing: false)
        try await cache.refreshFromFilesystem()
        let summary = try await cache.costSummary(budget: .init())
        XCTAssertEqual(summary.dailyCosts.count, 1)
        XCTAssertEqual(summary.dailyCosts.first?.outputTokens, 45)
        XCTAssertEqual(summary.dailyCosts.first?.inputTokens, 30)
        XCTAssertEqual(summary.dailyCosts.first?.sessionCount, 1)
    }

    func testFailedScanPreservesLastCompleteCacheAndSummary() async throws {
        let root = try temporaryDirectory()
        let projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let source = projects.appendingPathComponent("one.jsonl")
        let cacheURL = root.appendingPathComponent("cache.json")
        try row(output: 20).write(to: source)
        let cache = SessionParseCacheV2(projectsDirectory: projects, cacheURL: cacheURL, refreshPricing: false)
        try await cache.refreshFromFilesystem()
        let saved = try Data(contentsOf: cacheURL)
        try Data(repeating: 0x61, count: 9 * 1024 * 1024).write(to: projects.appendingPathComponent("oversized.jsonl"))
        do {
            try await cache.refreshFromFilesystem()
            XCTFail("Oversized row must stop the scan")
        } catch LocalStatsError.recordTooLarge { }
        XCTAssertEqual(try Data(contentsOf: cacheURL), saved)
        let summary = try await cache.costSummary(budget: .init())
        XCTAssertEqual(summary.dailyCosts.first?.outputTokens, 20)
    }

    func testUnavailableHistoryDoesNotEvictSavedEntries() async throws {
        let root = try temporaryDirectory()
        let projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let cacheURL = root.appendingPathComponent("cache.json")
        try row(output: 20).write(to: projects.appendingPathComponent("one.jsonl"))
        let cache = SessionParseCacheV2(projectsDirectory: projects, cacheURL: cacheURL, refreshPricing: false)
        try await cache.refreshFromFilesystem()
        let saved = try Data(contentsOf: cacheURL)
        try FileManager.default.removeItem(at: projects)
        do {
            try await cache.refreshFromFilesystem()
            XCTFail("Missing directory must not be treated as empty history")
        } catch LocalStatsError.historyUnavailable { }
        XCTAssertEqual(try Data(contentsOf: cacheURL), saved)
    }
}
