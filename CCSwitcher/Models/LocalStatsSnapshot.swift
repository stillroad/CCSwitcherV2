import Foundation

/// Small aggregate snapshot, separate from the potentially huge parse cache.
/// Relaunching the app must not trigger another full scan before the next day.
struct LocalStatsSnapshot: Codable, Sendable {
    let updatedAt: Date
    let cost: CostSummary
    let activity: ActivityStats

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("CCSwitcher/local-stats-summary.json")
    }

    static func load(from url: URL? = nil) -> LocalStatsSnapshot? {
        guard let data = try? Data(contentsOf: url ?? fileURL) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(to url: URL? = nil) {
        let target = url ?? Self.fileURL
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
    }
}
