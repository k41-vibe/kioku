import XCTest
@testable import Kioku

/// End-to-end tests against the real Rust core: open a fresh collection,
/// add notes, render, answer, undo, drill, split, export/import.
final class KiokuCoreTests: XCTestCase {
    var client: AnkiClient!

    override func setUpWithError() throws {
        let paths = try CollectionPaths.temporary()
        let backend = try AnkiBackend(preferredLangs: ["ja", "en"])
        client = AnkiClient(backend: backend, paths: paths)
        try client.openCollection()
    }

    override func tearDownWithError() throws {
        try? client.closeCollection()
        try? FileManager.default.removeItem(at: client.paths.root)
        client = nil
    }

    private func basicNotetypeID() throws -> Int64 {
        let names = try client.notetypeNames()
        XCTAssertFalse(names.isEmpty, "stock notetypes should exist")
        return names.first(where: { $0.name == "Basic" || $0.name == "基本" })?.id ?? names[0].id
    }

    @discardableResult
    private func addBasicNotes(deck: String, count: Int, prefix: String = "w") throws -> (deckID: Int64, noteIDs: [Int64]) {
        let did = try client.addDeck(named: deck)
        let ntid = try basicNotetypeID()
        var ids: [Int64] = []
        for i in 0..<count {
            var note = try client.newNote(notetypeID: ntid)
            note.fields[0] = "\(prefix)\(i) [sound:x\(i).mp3]"
            note.fields[1] = "answer \(i)"
            ids.append(try client.addNote(note, deckID: did))
        }
        return (did, ids)
    }

    func testOpenCollectionAndDeckTree() throws {
        let tree = try client.deckTree()
        XCTAssertEqual(tree.deckID, 0)
        XCTAssertGreaterThanOrEqual(tree.children.count, 1, "Default deck exists")
        let timing = try client.timingToday()
        XCTAssertGreaterThan(timing.nextDayAt, Int64(Date().timeIntervalSince1970))
        XCTAssertFalse(AnkiBackend.bridgeVersion.isEmpty)
    }

    func testRPCIndicesResolveToExpectedMethods() throws {
        // If service/method indices were wrong, these would decode garbage or throw.
        let status = try client.undoStatus()
        XCTAssertEqual(status.undo, "")
        let names = try client.deckNames()
        XCTAssertTrue(names.contains { $0.id == 1 })
    }

    func testAddNotesRenderAnswerUndo() throws {
        let (did, _) = try addBasicNotes(deck: "テスト", count: 5)
        let tree = try client.deckTree()
        let node = tree.children.first { $0.deckID == did }
        XCTAssertEqual(node?.newCount, 5)

        try client.setCurrentDeck(did)
        let queued = try client.queuedCards(limit: 1)
        XCTAssertEqual(queued.newCount, 5)
        let first = try XCTUnwrap(queued.cards.first)

        let rendered = try client.renderCard(first.card.id)
        let q = CardHTML.join(rendered.questionNodes)
        XCTAssertTrue(q.contains("w0"), "question should contain first field: \(q)")
        let av = try client.extractAVTags(q, questionSide: true)
        XCTAssertEqual(av.avTags.count, 1)
        XCTAssertTrue(av.text.contains("[anki:play:q:0]"))
        let html = CardHTML.replacePlayTags(av.text)
        XCTAssertTrue(html.contains("kioku-replay"))
        XCTAssertFalse(html.contains("[anki:play"))

        let labels = try client.describeNextStates(first.states)
        XCTAssertEqual(labels.count, 4)
        XCTAssertFalse(labels[2].isEmpty)

        try client.answerCard(first, rating: .good, millisecondsTaken: 1200)
        let after = try client.queuedCards(limit: 1)
        XCTAssertEqual(after.newCount, 4)
        XCTAssertEqual(after.learningCount, 1)

        let undo = try client.undoStatus()
        XCTAssertFalse(undo.undo.isEmpty)
        try client.undo()
        let restored = try client.queuedCards(limit: 1)
        XCTAssertEqual(restored.newCount, 5)
        XCTAssertEqual(restored.learningCount, 0)
        XCTAssertFalse(try client.undoStatus().redo.isEmpty)
        try client.redo()
        let redone = try client.queuedCards(limit: 1)
        XCTAssertEqual(redone.newCount, 4)
        XCTAssertEqual(redone.learningCount, 1)
    }

    func testImportIsUndoableAndRedoable() throws {
        let (did, _) = try addBasicNotes(deck: "元", count: 2, prefix: "u")
        let out = client.paths.inbox.appendingPathComponent("u.apkg").path
        _ = try client.exportAnkiPackage(deckID: did, to: out, withScheduling: false, withMedia: false)
        let paths2 = try CollectionPaths.temporary()
        let c2 = AnkiClient(backend: try AnkiBackend(), paths: paths2)
        try c2.openCollection()
        defer { try? c2.closeCollection(); try? FileManager.default.removeItem(at: paths2.root) }
        _ = try c2.importAnkiPackage(at: out)
        XCTAssertTrue(try c2.deckTree().children.contains { $0.name == "元" })
        XCTAssertFalse(try c2.undoStatus().undo.isEmpty)
        try c2.undo()
        XCTAssertFalse(try c2.deckTree().children.contains { $0.name == "元" })
        try c2.redo()
        XCTAssertTrue(try c2.deckTree().children.contains { $0.name == "元" && $0.totalInDeck == 2 })
    }

    func testTypeAnswerHelpers() throws {
        let q = "front<br>[[type:Back]]"
        let t = try XCTUnwrap(CardHTML.typeAnswerField(in: q))
        XCTAssertEqual(t.field, "Back")
        XCTAssertFalse(t.cloze)
        let injected = CardHTML.injectTypeInput(q, hasField: true)
        XCTAssertTrue(injected.contains("id=\"typeans\""))
        XCTAssertFalse(injected.contains("[[type:"))

        let cmp = try client.compareAnswer(expected: "apple", provided: "aple")
        XCTAssertTrue(cmp.contains("typeans"))
        XCTAssertTrue(cmp.contains("typeMissed") || cmp.contains("typeBad"))
        let a = "front<hr id=answer>[[type:Back]]"
        let out = CardHTML.injectTypeComparison(a, comparison: cmp)
        XCTAssertTrue(out.contains("<hr id=answer>"))
        XCTAssertTrue(out.contains("typeans"))
        XCTAssertFalse(out.contains("[[type:"))
    }

    func testDrillDoesNotTouchSchedule() throws {
        let (did, _) = try addBasicNotes(deck: "周回元", count: 3)
        let before = try client.deckTree().children.first { $0.deckID == did }
        let fid = try client.createFilteredDeck(name: "周回: 周回元", search: "deck:\"周回元\"", limit: 100, order: .added,
                                                reschedule: false, previewAgainSecs: 60, previewHardSecs: 600, previewGoodSecs: 0)
        try client.setCurrentDeck(fid)
        var answered = 0
        while answered < 10 {
            let q = try client.queuedCards(limit: 1)
            guard let c = q.cards.first else { break }
            try client.answerCard(c, rating: .good, millisecondsTaken: 500)
            answered += 1
        }
        XCTAssertEqual(answered, 3)
        try client.emptyFilteredDeck(fid)
        try client.removeDecks([fid])
        let after = try client.deckTree().children.first { $0.deckID == did }
        XCTAssertEqual(after?.newCount, before?.newCount)
        XCTAssertEqual(after?.totalInDeck, 3)
    }

    func testChapterSplitOrdersByNoteID() throws {
        let (did, _) = try addBasicNotes(deck: "鉄壁", count: 7)
        let ids = try client.searchCards("deck:\"鉄壁\"", orderSQL: "n.id asc, c.ord asc")
        XCTAssertEqual(ids.count, 7)
        var chapter = 1
        var i = 0
        while i < ids.count {
            let end = min(i + 3, ids.count)
            let name = "鉄壁::" + String(format: "%02d", chapter)
            let cid = try client.deckID(named: name) ?? (try client.addDeck(named: name))
            _ = try client.setDeck(cardIDs: Array(ids[i..<end]), deckID: cid)
            chapter += 1
            i = end
        }
        let parent = try XCTUnwrap(client.deckTree().children.first { $0.deckID == did })
        XCTAssertEqual(parent.children.count, 3)
        XCTAssertEqual(parent.children.map { $0.totalInDeck }, [3, 3, 1])
        XCTAssertEqual(parent.totalIncludingChildren, 7)
    }

    func testExportThenImportRoundTrip() throws {
        let (did, _) = try addBasicNotes(deck: "往復", count: 4, prefix: "rt")
        let out = client.paths.inbox.appendingPathComponent("rt.apkg").path
        let exported = try client.exportAnkiPackage(deckID: did, to: out, withScheduling: false, withMedia: false)
        XCTAssertEqual(exported, 4)
        try AppModel.validatePackage(at: URL(fileURLWithPath: out))

        // fresh collection
        let paths2 = try CollectionPaths.temporary()
        let client2 = AnkiClient(backend: try AnkiBackend(), paths: paths2)
        try client2.openCollection()
        defer { try? client2.closeCollection(); try? FileManager.default.removeItem(at: paths2.root) }
        let resp = try client2.importAnkiPackage(at: out)
        XCTAssertEqual(resp.log.new.count, 4)
        let tree = try client2.deckTree()
        XCTAssertTrue(tree.children.contains { $0.name == "往復" && $0.totalInDeck == 4 })
        // importing again is a no-op (dedup by guid)
        let again = try client2.importAnkiPackage(at: out)
        XCTAssertEqual(again.log.new.count, 0)
        XCTAssertEqual(again.log.duplicate.count, 4)
    }

    func testGraphsAndCardStats() throws {
        let (did, _) = try addBasicNotes(deck: "統計", count: 2)
        try client.setCurrentDeck(did)
        let q = try client.queuedCards(limit: 1)
        let c = try XCTUnwrap(q.cards.first)
        try client.answerCard(c, rating: .good, millisecondsTaken: 900)
        let g = try client.graphs(search: "deck:\"統計\"", days: 31)
        XCTAssertEqual(g.today.answerCount, 1)
        XCTAssertEqual(g.cardCounts.excludingInactive.newCards, 1)
        let stats = try client.cardStats(c.card.id)
        XCTAssertEqual(stats.reviews, 1)
        XCTAssertEqual(stats.revlog.count, 1)
    }

    func testBackendErrorIsDecoded() throws {
        XCTAssertThrowsError(try client.card(123456789)) { err in
            let e = err as? BackendError
            XCTAssertNotNil(e)
            XCTAssertEqual(e?.isNotFound, true)
        }
    }

    func testMediaSchemeHandlerBlocksTraversal() throws {
        let media = client.paths.media
        try "hello".data(using: .utf8)!.write(to: media.appendingPathComponent("a.txt"))
        let handler = MediaSchemeHandler(mediaFolder: media)
        let ok = handler.resolve(path: "/a.txt")
        XCTAssertEqual(ok?.lastPathComponent, "a.txt")
        XCTAssertNil(handler.resolve(path: "/../collection.anki2"))
        XCTAssertNil(handler.resolve(path: "/sub/x.png"))
        XCTAssertNil(handler.resolve(path: "/"))
    }
}
