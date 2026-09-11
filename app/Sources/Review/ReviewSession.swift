import Foundation
import Observation
import SwiftUI

/// One study session: normal review of a deck, or a preview-mode drill that
/// never touches the real schedule. The view shows a vertical reel:
/// page 0 = question, page 1 = answer, page 2 = next card's question.
@Observable
@MainActor
final class ReviewSession {
    enum Mode: Equatable {
        case normal
        case drill(filteredDeckID: Int64, title: String)
    }

    enum Phase: Equatable {
        case loading
        case studying
        case finished
        case error(String)
    }

    struct Counts: Equatable {
        var new: UInt32 = 0
        var learning: UInt32 = 0
        var review: UInt32 = 0
        var total: UInt32 { new + learning + review }
    }

    struct Current {
        var queued: QueuedCard
        var question: CardHTML.Side
        var answer: CardHTML.Side
        var css: String
        var labels: [String]
        var typeExpected: String?
        var shownAt: Date
        var questionHTML: String = ""
        var answerHTML: String = ""
    }

    let client: AnkiClient
    let deckID: Int64
    let deckName: String
    let mode: Mode
    let audio: CardAudioPlayer
    let web = CardWebController()

    var phase: Phase = .loading
    var current: Current?
    var next: Current?
    var counts = Counts()
    var answerRevealed = false
    var answeredCount = 0
    var againCount = 0
    var flash: String?
    var finishMessage: String = ""
    var errorMessage: String?
    var audioNotice: String?
    var night: Bool = false
    var forceMonochrome: Bool = UserDefaults.standard.object(forKey: "forceMonochrome") as? Bool ?? true
    /// Incremented every time a new card becomes current; the view uses it to reset paging.
    var generation = 0
    private var nextDayAt: Date = .distantFuture
    private var committing = false

    init(client: AnkiClient, deckID: Int64, deckName: String, mode: Mode) {
        self.client = client
        self.deckID = deckID
        self.deckName = deckName
        self.mode = mode
        self.audio = CardAudioPlayer(mediaFolder: client.paths.media)
        self.audio.onError = { [weak self] msg in
            Task { @MainActor in self?.audioNotice = msg }
        }
    }

    var isDrill: Bool {
        if case .drill = mode { return true }
        return false
    }

    var undoAvailable: Bool { answeredCount > 0 }

    // MARK: - Lifecycle

    func start() async {
        phase = .loading
        do {
            let targetDeck: Int64
            if case .drill(let fid, _) = mode { targetDeck = fid } else { targetDeck = deckID }
            let timing = try await client.perform { c in
                try c.setCurrentDeck(targetDeck)
                return try c.timingToday()
            }
            nextDayAt = Date(timeIntervalSince1970: TimeInterval(timing.nextDayAt))
            await loadNext(reuse: nil)
        } catch {
            phase = .error("\(error)")
        }
    }

    func end() async {
        audio.stop()
        if case .drill(let fid, _) = mode {
            _ = try? await client.perform { c in
                try c.emptyFilteredDeck(fid)
                try c.removeDecks([fid])
            }
        }
    }

    // MARK: - Queue (runs on the backend queue)

    nonisolated private static func fetch(_ c: AnkiClient, reuse: Current?) throws -> (Current?, Current?, Counts) {
        let queued = try c.queuedCards(limit: 2)
        let counts = Counts(new: queued.newCount, learning: queued.learningCount, review: queued.reviewCount)
        guard let first = queued.cards.first else { return (nil, nil, counts) }
        let cur: Current
        if let reuse, reuse.queued.card.id == first.card.id {
            cur = reuse
        } else {
            cur = try build(first, c)
        }
        var nxt: Current? = nil
        if queued.cards.count > 1 {
            nxt = try build(queued.cards[1], c)
        }
        return (cur, nxt, counts)
    }

    nonisolated private static func build(_ q: QueuedCard, _ c: AnkiClient) throws -> Current {
        let rendered = try c.renderCard(q.card.id)
        var qhtml = CardHTML.join(rendered.questionNodes)
        var ahtml = CardHTML.join(rendered.answerNodes)

        var typeExpected: String?
        var typeField: String?
        var typeCloze = false
        if let t = CardHTML.typeAnswerField(in: qhtml) {
            typeField = t.field
            typeCloze = t.cloze
            let note = try c.note(q.card.noteID)
            let names = try c.fieldNames(notetypeID: note.notetypeID)
            if let idx = names.firstIndex(of: t.field), idx < note.fields.count {
                var expected = note.fields[idx]
                if t.cloze {
                    expected = try c.extractClozeForTyping(expected, ordinal: q.card.templateIdx + 1)
                }
                if !expected.isEmpty { typeExpected = expected }
            }
        }
        qhtml = CardHTML.injectTypeInput(qhtml, hasField: typeExpected != nil)

        let qav = try c.extractAVTags(qhtml, questionSide: true)
        let aav = try c.extractAVTags(ahtml, questionSide: false)
        qhtml = CardHTML.replacePlayTags(qav.text)
        ahtml = CardHTML.replacePlayTags(aav.text)

        let labels = try c.describeNextStates(q.states)
        return Current(
            queued: q,
            question: CardHTML.Side(html: qhtml, avTags: qav.avTags, typeAnswerField: typeField, typeIsCloze: typeCloze),
            answer: CardHTML.Side(html: ahtml, avTags: aav.avTags, typeAnswerField: nil, typeIsCloze: false),
            css: rendered.css,
            labels: labels.count == 4 ? labels : ["", "", "", ""],
            typeExpected: typeExpected,
            shownAt: Date()
        )
    }

    private func render(_ cur: inout Current, comparison: String? = nil) {
        cur.questionHTML = CardHTML.document(body: cur.question.html, notetypeCSS: cur.css, cardOrdinal: cur.queued.card.templateIdx,
                                             night: night, forceMonochrome: forceMonochrome)
        let body = CardHTML.injectTypeComparison(cur.answer.html, comparison: comparison)
        cur.answerHTML = CardHTML.document(body: body, notetypeCSS: cur.css, cardOrdinal: cur.queued.card.templateIdx,
                                           night: night, forceMonochrome: forceMonochrome)
    }

    func loadNext(reuse: Current?) async {
        do {
            if Date() > nextDayAt {
                let timing = try await client.perform { c in try c.timingToday() }
                nextDayAt = Date(timeIntervalSince1970: TimeInterval(timing.nextDayAt))
            }
            let (cur, nxt, counts) = try await client.perform { c in try Self.fetch(c, reuse: reuse) }
            self.counts = counts
            guard var cur else {
                await finish()
                return
            }
            cur.shownAt = Date()
            render(&cur)
            if var n = nxt { render(&n); next = n } else { next = nil }
            current = cur
            answerRevealed = false
            generation += 1
            phase = .studying
            audio.play(cur.question.avTags)
        } catch {
            phase = .error("\(error)")
        }
    }

    // MARK: - Reveal / answer

    /// Called when the answer page becomes visible.
    func revealAnswer(typed: String? = nil) async {
        guard var cur = current, !answerRevealed else { return }
        if let expected = cur.typeExpected {
            let typedAnswer: String
            if let typed { typedAnswer = typed } else { typedAnswer = await web.readTypedAnswer() }
            let comparison = try? await client.perform { c in
                try c.compareAnswer(expected: expected, provided: typedAnswer, combining: true)
            }
            render(&cur, comparison: comparison)
            current = cur
        }
        answerRevealed = true
        audio.play(cur.answer.avTags)
    }

    /// Commit a rating for the current card and move to the next one.
    func answer(_ rating: Rating) async {
        guard let cur = current, phase == .studying, !committing else { return }
        committing = true
        defer { committing = false }
        let elapsedMs = Date().timeIntervalSince(cur.shownAt) * 1000
        let taken = UInt32(min(max(elapsedMs, 0), 3_600_000))
        let idx = Int(rating.rawValue)
        let label = idx >= 0 && idx < cur.labels.count ? cur.labels[idx] : ""
        audio.stop()
        do {
            try await client.perform { c in
                _ = try c.answerCard(cur.queued, rating: rating, millisecondsTaken: taken)
            }
            answeredCount += 1
            if rating == .again { againCount += 1 }
            let text = "\(ratingName(rating))  \(label)"
            flash = text
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                if self?.flash == text { self?.flash = nil }
            }
            await loadNext(reuse: next)
        } catch {
            phase = .error("\(error)")
        }
    }

    func ratingName(_ r: Rating) -> String {
        switch r {
        case .again: return "もう一度"
        case .hard: return "難しい"
        case .good: return "普通"
        case .easy: return "簡単"
        case .UNRECOGNIZED(_): return ""
        }
    }

    func undo() async {
        guard !committing else { return }
        audio.stop()
        phase = .loading
        do {
            _ = try await client.perform { c in try c.undo() }
            if answeredCount > 0 { answeredCount -= 1 }
            await loadNext(reuse: nil)
        } catch let e as BackendError where e.isUndoEmpty {
            await loadNext(reuse: nil)
        } catch {
            phase = .error("\(error)")
        }
    }

    func replayAudio() {
        guard let cur = current else { return }
        audio.play(answerRevealed ? cur.answer.avTags : cur.question.avTags)
    }

    func play(side: String, index: Int) {
        guard let cur = current else { return }
        let tags = side == "q" ? cur.question.avTags : cur.answer.avTags
        guard index >= 0, index < tags.count else { return }
        audio.play(single: tags[index])
    }

    // MARK: - Card tools

    var currentFlag: UInt32 { (current?.queued.card.flags ?? 0) & 0b111 }

    func setFlag(_ flag: UInt32) async {
        guard let cur = current else { return }
        do {
            try await client.perform { c in try c.setFlag(cardIDs: [cur.queued.card.id], flag: flag) }
            current?.queued.card.flags = (cur.queued.card.flags & ~UInt32(0b111)) | flag
        } catch { errorMessage = "\(error)" }
    }

    func buryCard() async {
        await cardOp { c, id in _ = try c.buryOrSuspend(cardIDs: [id], mode: .buryUser) }
    }

    func suspendCard() async {
        await cardOp { c, id in _ = try c.buryOrSuspend(cardIDs: [id], mode: .suspend) }
    }

    func forgetCard() async {
        await cardOp { c, id in try c.forgetCards([id]) }
    }

    private func cardOp(_ op: @escaping (AnkiClient, Int64) throws -> Void) async {
        guard let cur = current, !committing else { return }
        committing = true
        defer { committing = false }
        audio.stop()
        do {
            try await client.perform { c in try op(c, cur.queued.card.id) }
            answeredCount += 1
            await loadNext(reuse: nil)
        } catch {
            phase = .error("\(error)")
        }
    }

    func cardStats() async -> Anki_Stats_CardStatsResponse? {
        guard let cur = current else { return nil }
        return try? await client.perform { c in try c.cardStats(cur.queued.card.id) }
    }

    // MARK: - Finish

    private func finish() async {
        audio.stop()
        current = nil
        next = nil
        if isDrill {
            finishMessage = "この範囲を一周しました。\nもう一度: \(againCount) 回"
        } else {
            let msg = try? await client.perform { c in try c.studiedTodayMessage() }
            finishMessage = (msg?.isEmpty == false) ? msg! : "今日の分は終わりです。"
        }
        phase = .finished
    }
}
