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
            Task.detached(priority: .background) {
                _ = try? await client.perform { c in try c.createBackup(force: false) }
            }
        } catch {
            state = .failed("\(error)")
        }
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

    func importPackage(from url: URL) async {
        guard let client else {
            errorMessage = "コレクションがまだ開いていません"
            return
        }
        isImporting = true
        defer { isImporting = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let dest = client.paths.inbox.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            defer { try? FileManager.default.removeItem(at: dest) }
            try Self.validatePackage(at: dest)
            let resp = try await client.perform { c in try c.importAnkiPackage(at: dest.path) }
            importSummary = ImportSummary(
                fileName: url.lastPathComponent,
                added: resp.log.new.count,
                updated: resp.log.updated.count,
                duplicates: resp.log.duplicate.count,
                conflicting: resp.log.conflicting.count,
                found: Int(resp.log.foundNotes)
            )
            await refreshDecks()
        } catch {
            errorMessage = "取り込みに失敗しました: \(error)"
        }
    }

    /// Cheap sanity check before handing the file to rslib: it must be a zip.
    static func validatePackage(at url: URL) throws {
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
