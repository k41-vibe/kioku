import Foundation
import SwiftProtobuf

typealias DeckTreeNode = Anki_Decks_DeckTreeNode
typealias QueuedCard = Anki_Scheduler_QueuedCards.QueuedCard
typealias Rating = Anki_Scheduler_CardAnswer.Rating

/// Typed façade over the protobuf RPCs Kioku needs. Every method is
/// synchronous and blocking; use `perform` to run a batch on the backend
/// queue from async code.
final class AnkiClient: @unchecked Sendable {
    let backend: AnkiBackend
    let paths: CollectionPaths
    private let queue = DispatchQueue(label: "dev.k41.kioku.anki", qos: .userInitiated)

    init(backend: AnkiBackend, paths: CollectionPaths) {
        self.backend = backend
        self.paths = paths
    }

    /// Run `body` on the backend queue and return its result.
    func perform<T>(_ body: @escaping (AnkiClient) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body(self)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: - Collection lifecycle

    func openCollection() throws {
        var req = Anki_Collection_OpenCollectionRequest()
        req.collectionPath = paths.collection.path
        req.mediaFolderPath = paths.media.path
        req.mediaDbPath = paths.mediaDB.path
        try backend.invokeVoid(AnkiRPC.Collection.service, AnkiRPC.Collection.openCollection, req)
    }

    func closeCollection() throws {
        var req = Anki_Collection_CloseCollectionRequest()
        req.downgradeToSchema11 = false
        try backend.invokeVoid(AnkiRPC.Collection.service, AnkiRPC.Collection.closeCollection, req)
    }

    func createBackup(force: Bool) throws -> Bool {
        var req = Anki_Collection_CreateBackupRequest()
        req.backupFolder = paths.backups.path
        req.force = force
        req.waitForCompletion = true
        let r: Anki_Generic_Bool = try backend.invoke(AnkiRPC.Collection.service, AnkiRPC.Collection.createBackup, req)
        return r.val
    }

    func checkDatabase() throws -> [String] {
        let r: Anki_Collection_CheckDatabaseResponse = try backend.invoke(AnkiRPC.Collection.service, AnkiRPC.Collection.checkDatabase)
        return r.problems
    }

    // MARK: - Undo

    func undoStatus() throws -> Anki_Collection_UndoStatus {
        try backend.invoke(AnkiRPC.Collection.service, AnkiRPC.Collection.getUndoStatus)
    }

    @discardableResult
    func undo() throws -> Anki_Collection_OpChangesAfterUndo {
        try backend.invoke(AnkiRPC.Collection.service, AnkiRPC.Collection.undo)
    }

    @discardableResult
    func redo() throws -> Anki_Collection_OpChangesAfterUndo {
        try backend.invoke(AnkiRPC.Collection.service, AnkiRPC.Collection.redo)
    }

    // MARK: - Scheduler

    func timingToday() throws -> Anki_Scheduler_SchedTimingTodayResponse {
        try backend.invoke(AnkiRPC.Scheduler.service, AnkiRPC.Scheduler.schedTimingToday)
    }

    func queuedCards(limit: UInt32 = 1, intradayLearningOnly: Bool = false) throws -> Anki_Scheduler_QueuedCards {
        var req = Anki_Scheduler_GetQueuedCardsRequest()
        req.fetchLimit = limit
        req.intradayLearningOnly = intradayLearningOnly
        return try backend.invoke(AnkiRPC.Scheduler.service, AnkiRPC.Scheduler.getQueuedCards, req)
    }

    func describeNextStates(_ states: Anki_Scheduler_SchedulingStates) throws -> [String] {
        let r: Anki_Generic_StringList = try backend.invoke(AnkiRPC.Scheduler.service, AnkiRPC.Scheduler.describeNextStates, states)
        return r.vals
    }

    @discardableResult
    func answerCard(_ card: QueuedCard, rating: Rating, millisecondsTaken: UInt32) throws -> Anki_Collection_OpChanges {
        var answer = Anki_Scheduler_CardAnswer()
        answer.cardID = card.card.id
        answer.currentState = card.states.current
        switch rating {
        case .again: answer.newState = card.states.again
        case .hard: answer.newState = card.states.hard
        case .good: answer.newState = card.states.good
        case .easy: answer.newState = card.states.easy
        case .UNRECOGNIZED(_): answer.newState = card.states.good
        }
        answer.rating = rating
        answer.answeredAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        answer.millisecondsTaken = millisecondsTaken
        return try backend.invoke(AnkiRPC.Scheduler.service, AnkiRPC.Scheduler.answerCard, answer)
    }

    func congratsInfo() throws -> Anki_Scheduler_CongratsInfoResponse {
        try backend.invoke(AnkiRPC.Scheduler.service, AnkiRPC.Scheduler.congratsInfo)
    }

    func studiedTodayMessage() throws -> String {
        let r: Anki_Generic_String = try backend.invoke(AnkiRPC.Scheduler.service, AnkiRPC.Scheduler.studiedToday)
        return r.val
    }

    @discardableResult
    func buryOrSuspend(cardIDs: [Int64], mode: Anki_Scheduler_BuryOrSuspendCardsRequest.Mode) throws -> UInt32 {
        var req = Anki_Scheduler_BuryOrSuspendCardsRequest()
        req.cardIds = cardIDs
        req.mode = mode
        let r: Anki_Collection_OpChangesWithCount = try backend.invoke(AnkiRPC.Scheduler.service, AnkiRPC.Scheduler.buryOrSuspendCards, req)
        return r.count
    }

    func unburyDeck(_ deckID: Int64) throws {
        var req = Anki_Scheduler_UnburyDeckRequest()
        req.deckID = deckID
        req.mode = .all
        try backend.invokeVoid(AnkiRPC.Scheduler.service, AnkiRPC.Scheduler.unburyDeck, req)
    }

    func extendLimits(deckID: Int64, newDelta: Int32, reviewDelta: Int32) throws {
        var req = Anki_Scheduler_ExtendLimitsRequest()
        req.deckID = deckID
        req.newDelta = newDelta
        req.reviewDelta = reviewDelta
        try backend.invokeVoid(AnkiRPC.Scheduler.service, AnkiRPC.Scheduler.extendLimits, req)
    }

    func emptyFilteredDeck(_ deckID: Int64) throws {
        var req = Anki_Decks_DeckId()
        req.did = deckID
        try backend.invokeVoid(AnkiRPC.Scheduler.service, AnkiRPC.Scheduler.emptyFilteredDeck, req)
    }

    func rebuildFilteredDeck(_ deckID: Int64) throws -> UInt32 {
        var req = Anki_Decks_DeckId()
        req.did = deckID
        let r: Anki_Collection_OpChangesWithCount = try backend.invoke(AnkiRPC.Scheduler.service, AnkiRPC.Scheduler.rebuildFilteredDeck, req)
        return r.count
    }

    func forgetCards(_ cardIDs: [Int64]) throws {
        var req = Anki_Scheduler_ScheduleCardsAsNewRequest()
        req.cardIds = cardIDs
        req.log = true
        req.restorePosition = false
        req.resetCounts = false
        req.context = .reviewer
        try backend.invokeVoid(AnkiRPC.Scheduler.service, AnkiRPC.Scheduler.scheduleCardsAsNew, req)
    }

    // MARK: - Decks

    func deckTree(now: Date? = Date()) throws -> DeckTreeNode {
        var req = Anki_Decks_DeckTreeRequest()
        req.now = now.map { Int64($0.timeIntervalSince1970) } ?? 0
        return try backend.invoke(AnkiRPC.Decks.service, AnkiRPC.Decks.deckTree, req)
    }

    func deckNames(includeFiltered: Bool = true) throws -> [Anki_Decks_DeckNameId] {
        var req = Anki_Decks_GetDeckNamesRequest()
        req.skipEmptyDefault = false
        req.includeFiltered = includeFiltered
        let r: Anki_Decks_DeckNames = try backend.invoke(AnkiRPC.Decks.service, AnkiRPC.Decks.getDeckNames, req)
        return r.entries
    }

    func deck(_ id: Int64) throws -> Anki_Decks_Deck {
        var req = Anki_Decks_DeckId()
        req.did = id
        return try backend.invoke(AnkiRPC.Decks.service, AnkiRPC.Decks.getDeck, req)
    }

    func updateDeck(_ deck: Anki_Decks_Deck) throws {
        try backend.invokeVoid(AnkiRPC.Decks.service, AnkiRPC.Decks.updateDeck, deck)
    }

    func currentDeck() throws -> Anki_Decks_Deck {
        try backend.invoke(AnkiRPC.Decks.service, AnkiRPC.Decks.getCurrentDeck)
    }

    func setCurrentDeck(_ id: Int64) throws {
        var req = Anki_Decks_DeckId()
        req.did = id
        try backend.invokeVoid(AnkiRPC.Decks.service, AnkiRPC.Decks.setCurrentDeck, req)
    }

    func setDeckCollapsed(_ id: Int64, collapsed: Bool) throws {
        var req = Anki_Decks_SetDeckCollapsedRequest()
        req.deckID = id
        req.collapsed = collapsed
        req.scope = .reviewer
        try backend.invokeVoid(AnkiRPC.Decks.service, AnkiRPC.Decks.setDeckCollapsed, req)
    }

    /// Create a normal deck with the given full name ("Parent::Child"); returns its id.
    func addDeck(named name: String) throws -> Int64 {
        var deck: Anki_Decks_Deck = try backend.invoke(AnkiRPC.Decks.service, AnkiRPC.Decks.newDeck)
        deck.name = name
        let r: Anki_Collection_OpChangesWithId = try backend.invoke(AnkiRPC.Decks.service, AnkiRPC.Decks.addDeck, deck)
        return r.id
    }

    func deckID(named name: String) throws -> Int64? {
        var req = Anki_Generic_String()
        req.val = name
        do {
            let r: Anki_Decks_DeckId = try backend.invoke(AnkiRPC.Decks.service, AnkiRPC.Decks.getDeckIdByName, req)
            return r.did == 0 ? nil : r.did
        } catch let e as BackendError where e.isNotFound {
            return nil
        }
    }

    func renameDeck(_ id: Int64, to newName: String) throws {
        var req = Anki_Decks_RenameDeckRequest()
        req.deckID = id
        req.newName = newName
        try backend.invokeVoid(AnkiRPC.Decks.service, AnkiRPC.Decks.renameDeck, req)
    }

    @discardableResult
    func removeDecks(_ ids: [Int64]) throws -> UInt32 {
        var req = Anki_Decks_DeckIds()
        req.dids = ids
        let r: Anki_Collection_OpChangesWithCount = try backend.invoke(AnkiRPC.Decks.service, AnkiRPC.Decks.removeDecks, req)
        return r.count
    }

    /// Create (or update) a filtered deck. `reschedule == false` makes it a
    /// preview/cram deck that never touches the cards' real schedule.
    func createFilteredDeck(name: String, search: String, limit: UInt32, order: Anki_Decks_Deck.Filtered.SearchTerm.Order,
                            reschedule: Bool, previewAgainSecs: UInt32 = 60, previewHardSecs: UInt32 = 600, previewGoodSecs: UInt32 = 0) throws -> Int64 {
        var get = Anki_Decks_DeckId()
        get.did = 0
        var deck: Anki_Decks_FilteredDeckForUpdate = try backend.invoke(AnkiRPC.Decks.service, AnkiRPC.Decks.getOrCreateFilteredDeck, get)
        deck.name = name
        var term = Anki_Decks_Deck.Filtered.SearchTerm()
        term.search = search
        term.limit = limit
        term.order = order
        deck.config.searchTerms = [term]
        deck.config.reschedule = reschedule
        deck.config.previewAgainSecs = previewAgainSecs
        deck.config.previewHardSecs = previewHardSecs
        deck.config.previewGoodSecs = previewGoodSecs
        deck.allowEmpty = false
        let r: Anki_Collection_OpChangesWithId = try backend.invoke(AnkiRPC.Decks.service, AnkiRPC.Decks.addOrUpdateFilteredDeck, deck)
        return r.id
    }

    // MARK: - Cards / notes

    func card(_ id: Int64) throws -> Anki_Cards_Card {
        var req = Anki_Cards_CardId()
        req.cid = id
        return try backend.invoke(AnkiRPC.Cards.service, AnkiRPC.Cards.getCard, req)
    }

    func setFlag(cardIDs: [Int64], flag: UInt32) throws {
        var req = Anki_Cards_SetFlagRequest()
        req.cardIds = cardIDs
        req.flag = flag
        let _: Anki_Collection_OpChangesWithCount = try backend.invoke(AnkiRPC.Cards.service, AnkiRPC.Cards.setFlag, req)
    }

    @discardableResult
    func setDeck(cardIDs: [Int64], deckID: Int64) throws -> UInt32 {
        var req = Anki_Cards_SetDeckRequest()
        req.cardIds = cardIDs
        req.deckID = deckID
        let r: Anki_Collection_OpChangesWithCount = try backend.invoke(AnkiRPC.Cards.service, AnkiRPC.Cards.setDeck, req)
        return r.count
    }

    func note(_ id: Int64) throws -> Anki_Notes_Note {
        var req = Anki_Notes_NoteId()
        req.nid = id
        return try backend.invoke(AnkiRPC.Notes.service, AnkiRPC.Notes.getNote, req)
    }

    func fieldNames(notetypeID: Int64) throws -> [String] {
        var req = Anki_Notetypes_NotetypeId()
        req.ntid = notetypeID
        let r: Anki_Generic_StringList = try backend.invoke(AnkiRPC.Notetypes.service, AnkiRPC.Notetypes.getFieldNames, req)
        return r.vals
    }

    func notetypeNames() throws -> [Anki_Notetypes_NotetypeNameId] {
        let r: Anki_Notetypes_NotetypeNames = try backend.invoke(AnkiRPC.Notetypes.service, AnkiRPC.Notetypes.getNotetypeNames)
        return r.entries
    }

    func newNote(notetypeID: Int64) throws -> Anki_Notes_Note {
        var req = Anki_Notetypes_NotetypeId()
        req.ntid = notetypeID
        return try backend.invoke(AnkiRPC.Notes.service, AnkiRPC.Notes.newNote, req)
    }

    func addNote(_ note: Anki_Notes_Note, deckID: Int64) throws -> Int64 {
        var req = Anki_Notes_AddNoteRequest()
        req.note = note
        req.deckID = deckID
        let r: Anki_Notes_AddNoteResponse = try backend.invoke(AnkiRPC.Notes.service, AnkiRPC.Notes.addNote, req)
        return r.noteID
    }

    // MARK: - Search

    /// Returns card ids matching `search`. `orderSQL` is an ORDER BY clause over
    /// the `c` (cards) / `n` (notes) aliases, e.g. "n.id asc, c.ord asc".
    func searchCards(_ search: String, orderSQL: String? = nil) throws -> [Int64] {
        var req = Anki_Search_SearchRequest()
        req.search = search
        if let orderSQL {
            var order = Anki_Search_SortOrder()
            order.custom = orderSQL
            req.order = order
        }
        let r: Anki_Search_SearchResponse = try backend.invoke(AnkiRPC.Search.service, AnkiRPC.Search.searchCards, req)
        return r.ids
    }

    // MARK: - Rendering

    func renderCard(_ cardID: Int64) throws -> Anki_CardRendering_RenderCardResponse {
        var req = Anki_CardRendering_RenderExistingCardRequest()
        req.cardID = cardID
        req.browser = false
        req.partialRender = false
        return try backend.invoke(AnkiRPC.CardRendering.service, AnkiRPC.CardRendering.renderExistingCard, req)
    }

    func extractAVTags(_ text: String, questionSide: Bool) throws -> Anki_CardRendering_ExtractAvTagsResponse {
        var req = Anki_CardRendering_ExtractAvTagsRequest()
        req.text = text
        req.questionSide = questionSide
        return try backend.invoke(AnkiRPC.CardRendering.service, AnkiRPC.CardRendering.extractAvTags, req)
    }

    func compareAnswer(expected: String, provided: String, combining: Bool = true) throws -> String {
        var req = Anki_CardRendering_CompareAnswerRequest()
        req.expected = expected
        req.provided = provided
        req.combining = combining
        let r: Anki_Generic_String = try backend.invoke(AnkiRPC.CardRendering.service, AnkiRPC.CardRendering.compareAnswer, req)
        return r.val
    }

    func extractClozeForTyping(_ text: String, ordinal: UInt32) throws -> String {
        var req = Anki_CardRendering_ExtractClozeForTypingRequest()
        req.text = text
        req.ordinal = ordinal
        let r: Anki_Generic_String = try backend.invoke(AnkiRPC.CardRendering.service, AnkiRPC.CardRendering.extractClozeForTyping, req)
        return r.val
    }

    func stripHTML(_ text: String) throws -> String {
        var req = Anki_CardRendering_StripHtmlRequest()
        req.text = text
        req.mode = .normal
        let r: Anki_Generic_String = try backend.invoke(AnkiRPC.CardRendering.service, AnkiRPC.CardRendering.stripHtml, req)
        return r.val
    }

    // MARK: - Import / export

    func importAnkiPackage(at path: String) throws -> Anki_ImportExport_ImportResponse {
        var req = Anki_ImportExport_ImportAnkiPackageRequest()
        req.packagePath = path
        var opts = Anki_ImportExport_ImportAnkiPackageOptions()
        opts.mergeNotetypes = false
        opts.updateNotes = .ifNewer
        opts.updateNotetypes = .ifNewer
        opts.withScheduling = true
        opts.withDeckConfigs = false
        req.options = opts
        return try backend.invoke(AnkiRPC.ImportExport.service, AnkiRPC.ImportExport.importAnkiPackage, req)
    }

    func exportAnkiPackage(deckID: Int64?, to path: String, withScheduling: Bool, withMedia: Bool) throws -> UInt32 {
        var req = Anki_ImportExport_ExportAnkiPackageRequest()
        req.outPath = path
        var opts = Anki_ImportExport_ExportAnkiPackageOptions()
        opts.withScheduling = withScheduling
        opts.withDeckConfigs = false
        opts.withMedia = withMedia
        opts.legacy = false
        req.options = opts
        var limit = Anki_ImportExport_ExportLimit()
        if let deckID {
            limit.limit = .deckID(deckID)
        } else {
            limit.limit = .wholeCollection(Anki_Generic_Empty())
        }
        req.limit = limit
        let r: Anki_Generic_UInt32 = try backend.invoke(AnkiRPC.ImportExport.service, AnkiRPC.ImportExport.exportAnkiPackage, req)
        return r.val
    }

    // MARK: - Stats

    func graphs(search: String, days: UInt32) throws -> Anki_Stats_GraphsResponse {
        var req = Anki_Stats_GraphsRequest()
        req.search = search
        req.days = days
        return try backend.invoke(AnkiRPC.Stats.service, AnkiRPC.Stats.graphs, req)
    }

    func cardStats(_ cardID: Int64) throws -> Anki_Stats_CardStatsResponse {
        var req = Anki_Cards_CardId()
        req.cid = cardID
        return try backend.invoke(AnkiRPC.Stats.service, AnkiRPC.Stats.cardStats, req)
    }

    // MARK: - Config

    func configJSON(_ key: String) throws -> Data? {
        var req = Anki_Generic_String()
        req.val = key
        do {
            let r: Anki_Generic_Json = try backend.invoke(AnkiRPC.Config.service, AnkiRPC.Config.getConfigJson, req)
            return r.json
        } catch let e as BackendError where e.isNotFound {
            return nil
        }
    }

    func setConfigJSON(_ key: String, json: Data) throws {
        var req = Anki_Config_SetConfigJsonRequest()
        req.key = key
        req.valueJson = json
        req.undoable = false
        try backend.invokeVoid(AnkiRPC.Config.service, AnkiRPC.Config.setConfigJsonNoUndo, req)
    }
}
