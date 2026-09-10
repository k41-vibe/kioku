import Foundation
import Observation
import SwiftUI

struct ImportSummary: Identifiable {
    let id = UUID()
    let fileName: String
    let added: Int
    let updated: Int
    let duplicates: Int
    let conflicting: Int
    let found: Int

    var text: String {
        "追加 \(added) / 更新 \(updated) / 重複 \(duplicates)" + (conflicting > 0 ? " / 競合 \(conflicting)" : "")
    }
}

@Observable
@MainActor
final class AppModel {
    enum State {
        case loading
        case ready
        case failed(String)
    }

    var state: State = .loading
    private(set) var client: AnkiClient?
    var deckTree: DeckTreeNode?
    var deckNames: [Int64: String] = [:]
    var errorMessage: String?
    var importSummary: ImportSummary?
    var isImporting = false
    var undoLabel: String = ""
    /// .apkg files found in Documents (dropped there via the Files app).
    var pendingPackages: [URL] = []
    /// Recent import diagnostics, newest last (shown in settings).
    var importLog: [String] = []
    /// URLs handed to us (share sheet / open-in) before the collection was ready.
    private var queuedOpenURLs: [URL] = []

    private func log(_ s: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        importLog.append("[\(stamp)] \(s)")
        if importLog.count > 40 { importLog.removeFirst(importLog.count - 40) }
    }

    var forceMonochrome: Bool {
        get { UserDefaults.standard.object(forKey: "forceMonochrome") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "forceMonochrome") }
    }

    func start() async {
        state = .loading
        do {
            let paths = try CollectionPaths.default()
            let backend = try AnkiBackend(preferredLangs: ["ja", "en"])
            let client = AnkiClient(backend: backend, paths: paths)
            try await client.perform { c in try c.openCollection() }
            self.client = client
            state = .ready
            await refreshDecks()
            scanDocuments()
            Task.detached(priority: .background) {
                _ = try? await client.perform { c in try c.createBackup(force: false) }
            }
            let queued = queuedOpenURLs
            queuedOpenURLs.removeAll()
            for url in queued { await importPackage(from: url) }
        } catch {
            state = .failed("\(error)")
        }
    }

    /// Called from onOpenURL. Defers until the collection is open.
    func handleOpenURL(_ url: URL) async {
        log("open-url: \(url.lastPathComponent) (\(url.scheme ?? "?"))")
        if client == nil {
            queuedOpenURLs.append(url)
            return
        }
        await importPackage(from: url)
    }

    func scanDocuments() {
        pendingPackages = CollectionPaths.pendingPackages()
    }

    /// Import every package sitting in Documents, then move it to Documents/imported.
    func importPendingPackages() async {
        let files = CollectionPaths.pendingPackages()
        for file in files {
            let ok = await importPackage(from: file)
            if ok {
                let dest = CollectionPaths.importedFolder
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                let target = dest.appendingPathComponent(file.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.moveItem(at: file, to: target)
            }
        }
        scanDocuments()
    }

    func refreshDecks() async {
        guard let client else { return }
        do {
            let (tree, names, undo) = try await client.perform { c in
                (try c.deckTree(), try c.deckNames(), try c.undoStatus())
            }
            deckTree = tree
            deckNames = Dictionary(uniqueKeysWithValues: names.map { ($0.id, $0.name) })
            undoLabel = undo.undo
        } catch {
            errorMessage = "\(error)"
        }
    }

    func undo() async {
        guard let client else { return }
        do {
            _ = try await client.perform { c in try c.undo() }
            await refreshDecks()
        } catch let e as BackendError where e.isUndoEmpty {
            undoLabel = ""
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Import

    @discardableResult
    func importPackage(from url: URL) async -> Bool {
        guard let client else {
            queuedOpenURLs.append(url)
            log("queued (collection not open yet): \(url.lastPathComponent)")
            return false
        }
        isImporting = true
        defer { isImporting = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        log("import start: \(url.path) scoped=\(accessed)")
        do {
            let fm = FileManager.default
            let name = url.lastPathComponent.isEmpty ? "package.apkg" : url.lastPathComponent
            let dest = client.paths.inbox.appendingPathComponent(name)
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: url, to: dest)
            } catch {
                // Some providers refuse copyItem but allow reading; fall back to Data.
                log("copyItem failed (\(error.localizedDescription)); trying Data read")
                let data = try Data(contentsOf: url)
                try data.write(to: dest)
            }
            defer { try? fm.removeItem(at: dest) }
            let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? -1
            log("copied \(size) bytes to inbox")
            try Self.validatePackage(at: dest)
            let resp = try await client.perform { c in try c.importAnkiPackage(at: dest.path) }
            let summary = ImportSummary(
                fileName: name,
                added: resp.log.new.count,
                updated: resp.log.updated.count,
                duplicates: resp.log.duplicate.count,
                conflicting: resp.log.conflicting.count,
                found: Int(resp.log.foundNotes)
            )
            log("import ok: \(summary.text)")
            importSummary = summary
            await refreshDecks()
            return true
        } catch {
            log("import failed: \(error)")
            errorMessage = "取り込みに失敗しました: \(error)"
            return false
        }
    }

    /// Cheap sanity check before handing the file to rslib: it must be a zip.
    nonisolated static func validatePackage(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        guard magic.count == 4, magic[0] == 0x50, magic[1] == 0x4B else {
            throw BackendError(kind: .ffi, message: "Anki のパッケージ(.apkg / .colpkg)ではありません")
        }
    }

    // MARK: - Deck helpers

    func deckName(_ id: Int64) -> String {
        deckNames[id] ?? "デッキ"
    }

    func node(for deckID: Int64) -> DeckTreeNode? {
        guard let deckTree else { return nil }
        return Self.find(deckID, in: deckTree)
    }

    private static func find(_ id: Int64, in node: DeckTreeNode) -> DeckTreeNode? {
        if node.deckID == id { return node }
        for child in node.children {
            if let hit = find(id, in: child) { return hit }
        }
        return nil
    }

    func deleteDeck(_ id: Int64) async {
        guard let client else { return }
        do {
            _ = try await client.perform { c in try c.removeDecks([id]) }
            await refreshDecks()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func renameDeck(_ id: Int64, to name: String) async {
        guard let client else { return }
        do {
            try await client.perform { c in try c.renameDeck(id, to: name) }
            await refreshDecks()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func setCollapsed(_ id: Int64, _ collapsed: Bool) async {
        guard let client else { return }
        _ = try? await client.perform { c in try c.setDeckCollapsed(id, collapsed: collapsed) }
    }
}
