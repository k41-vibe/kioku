import Foundation

/// Where the collection lives on disk. Always derived at runtime: LiveContainer
/// relocates the app container, so absolute paths must never be persisted.
struct CollectionPaths {
    let root: URL
    var collection: URL { root.appendingPathComponent("collection.anki2") }
    var media: URL { root.appendingPathComponent("collection.media", isDirectory: true) }
    var mediaDB: URL { root.appendingPathComponent("collection.media.db") }
    var backups: URL { root.appendingPathComponent("backups", isDirectory: true) }
    var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }

    static func `default`(profile: String = "default") throws -> CollectionPaths {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("Kioku", isDirectory: true).appendingPathComponent(profile, isDirectory: true)
        let paths = CollectionPaths(root: root)
        try paths.ensureDirectories()
        return paths
    }

    static func temporary(name: String = UUID().uuidString) throws -> CollectionPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kioku-\(name)", isDirectory: true)
        let paths = CollectionPaths(root: root)
        try paths.ensureDirectories()
        return paths
    }

    func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, media, backups, inbox] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }
}
