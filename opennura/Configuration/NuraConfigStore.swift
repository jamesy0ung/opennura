import Foundation

final class NuraConfigStore {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "opennura"
        let dir = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")
    }

    func load() -> NuraConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return NuraConfig() }
        do {
            return try JSONDecoder().decode(NuraConfig.self, from: data)
        } catch {
            return NuraConfig()
        }
    }

    func save(_ config: NuraConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(config)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Config save is best-effort
        }
    }
}
