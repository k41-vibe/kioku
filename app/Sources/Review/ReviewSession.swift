import Foundation
import Observation
import SwiftUI

/// Notetype lookups cached for a session (thread-safe; used from the backend queue).
final class NotetypeCache: @unchecked Sendable {
    private var map: [Int64: Anki_Notetypes_Notetype] = [:]
    private let lock = NSLock()
    func get(_ id: Int64, _ c: AnkiClient) throws -> Anki_Notetypes_Notetype {
        lock.lock(); defer { lock.unlock() }
        if let nt = map[id] { return nt }
        let nt = try c.notetype(id)
        map[id] = nt
        return nt
    }
    func invalidate(_ id: Int64) { lock.lock(); map[id] = nil; lock.unlock() }
}

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
        var memo: String = ""
        var note: Anki_Notes_Note? = nil
        var memoFieldIndex: Int? = nil
        /// Kioku layout built from the fields; nil when the note does not fit it.
        var native: NativeCard? = nil
    }

    let notetypes = NotetypeCache()
    var showExtraFields: Bool = UserDefaults.standard.object(forKey: "showExtraFields") as? Bool ?? true
    var useNativeLayout: Bool = UserDefaults.standard.object(forKey: "nativeLayout") as? Bool ?? true

    let client: AnkiClient
    let deckID: Int64
    let deckName: String
    let mode: Mode
    let audio: CardAudioPlayer
    let web = CardWebController()

    var phase: Phase = .loading
    var current: Current?
    var next: Current?
    /// Cards answered in this session, oldest first (capped). Scrolling back
    /// onto the last one undoes its answer.
    var history: [Current] = []
    var previous: Current? { history.last }
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

    nonisolated private static func fetch(_ c: AnkiClient, reuse: Current?, cache: NotetypeCache, extras: Bool) throws -> (Current?, Current?, Counts) {
        let queued = try c.queuedCards(limit: 2)
        let counts = Counts(new: queued.newCount, learning: queued.learningCount, review: queued.reviewCount)
        guard let first = queued.cards.first else { return (nil, nil, counts) }
        let cur: Current
        if let reuse, reuse.queued.card.id == first.card.id {
            cur = reuse
        } else {
            cur = try build(first, c, cache: cache, extras: extras)
        }
        var nxt: Current? = nil
        if queued.cards.count > 1 {
            nxt = try build(queued.cards[1], c, cache: cache, extras: extras)
        }
        return (cur, nxt, counts)
    }

    nonisolated private static func build(_ q: QueuedCard, _ c: AnkiClient, cache: NotetypeCache, extras: Bool) throws -> Current {
        let rendered = try c.renderCard(q.card.id)
        var qhtml = CardHTML.join(rendered.questionNodes)
        var ahtml = CardHTML.join(rendered.answerNodes)

        let note = try c.note(q.card.noteID)
        let nt = try cache.get(note.notetypeID, c)
        let names = nt.fields.map { $0.name }

        var typeExpected: String?
        var typeField: String?
        var typeCloze = false
        if let t = CardHTML.typeAnswerField(in: qhtml) {
            typeField = t.field
            typeCloze = t.cloze
            if let idx = names.firstIndex(of: t.field), idx < note.fields.count {
                var expected = note.fields[idx]
                if t.cloze {
                    expected = try c.extractClozeForTyping(expected, ordinal: q.card.templateIdx + 1)
                }
                if !expected.isEmpty { typeExpected = expected }
            }
        }
        qhtml = CardHTML.injectTypeInput(qhtml, hasField: typeExpected != nil)

        // Memo field (native UI) and fields the template never shows (appended to the answer).
        let memoIdx = names.firstIndex(of: CardHTML.memoFieldName)
        let memo = memoIdx.flatMap { $0 < note.fields.count ? note.fields[$0] : nil } ?? ""
        if extras {
            let templates = nt.templates.flatMap { [$0.config.qFormat, $0.config.aFormat] }
            let used = CardHTML.referencedFields(in: templates)
            var pairs: [(String, String)] = []
            for (i, name) in names.enumerated() where i < note.fields.count {
                if name == CardHTML.memoFieldName || used.contains(name) { continue }
                let v = note.fields[i]
                if v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                pairs.append((name, v))
            }
            ahtml += CardHTML.extraFieldsHTML(pairs)
        }

        let qav = try c.extractAVTags(qhtml, questionSide: true)
        let aav = try c.extractAVTags(ahtml, questionSide: false)
        qhtml = CardHTML.replacePlayTags(qav.text)
        ahtml = CardHTML.replacePlayTags(aav.text)

        // Kioku layout (native), unless the card needs typing.
        var native: NativeCard? = nil
        if typeExpected == nil {
            native = NativeCard.build(note: note, notetype: nt, memoField: CardHTML.memoFieldName, strip: { html in
                let withBreaks = html.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
                    .replacingOccurrences(of: "<br />", with: "\n").replacingOccurrences(of: "</div>", with: "\n").replacingOccurrences(of: "</p>", with: "\n")
                return (try? c.stripHTML(withBreaks)) ?? withBreaks
            }, avTags: { text in
                (try? c.extractAVTags(text, questionSide: true).avTags) ?? []
            })
        }

        let labels = try c.describeNextStates(q.states)
        return Current(
            queued: q,
            question: CardHTML.Side(html: qhtml, avTags: qav.avTags, typeAnswerField: typeField, typeIsCloze: typeCloze),
            answer: CardHTML.Side(html: ahtml, avTags: aav.avTags, typeAnswerField: nil, typeIsCloze: false),
            css: rendered.css,
            labels: labels.count == 4 ? labels : ["", "", "", ""],
            typeExpected: typeExpected,
            shownAt: Date(),
            memo: memo,
            note: note,
            memoFieldIndex: memoIdx,
            native: native
        )
    }

    /// True when the current card is shown with the Kioku layout.
    var isNative: Bool { useNativeLayout && current?.native != nil }

    func playQuestionAudio() {
        guard let cur = current else { return }
        if isNative, let n = cur.native { audio.play(n.questionAudio) } else { audio.play(cur.question.avTags) }
    }

    func playAnswerAudio() {
        guard let cur = current else { return }
        if isNative, let n = cur.native { audio.play(n.answerAudio) } else { audio.play(cur.answer.avTags) }
    }

    /// Save a memo into the note field named メモ, creating the field if needed.
    func saveMemo(_ text: String) async {
        guard var cur = current, let note = cur.note else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == cur.memo { return }
        let ntid = note.notetypeID
        let noteID = note.id
        do {
            let (idx, saved) = try await client.perform { [notetypes] c -> (Int, Anki_Notes_Note) in
                let idx = try c.ensureField(named: CardHTML.memoFieldName, notetypeID: ntid)
                notetypes.invalidate(ntid)
                var n = try c.note(noteID)
                while n.fields.count <= idx { n.fields.append("") }
                n.fields[idx] = trimmed.replacingOccurrences(of: "\n", with: "<br>")
                try c.updateNote(n)
                return (idx, n)
            }
            cur.memo = trimmed
            cur.note = saved
            cur.memoFieldIndex = idx
            current = cur
        } catch {
            errorMessage = "メモを保存できませんでした: \(error)"
        }
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
            let (cur, nxt, counts) = try await client.perform { [notetypes, showExtraFields] c in try Self.fetch(c, reuse: reuse, cache: notetypes, extras: showExtraFields) }
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
            playQuestionAudio()
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
        playAnswerAudio()
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
            pushHistory(cur)
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

    private func pushHistory(_ cur: Current) {
        history.append(cur)
        if history.count > 20 { history.removeFirst(history.count - 20) }
    }

    func undo() async {
        guard !committing else { return }
        committing = true
        defer { committing = false }
        audio.stop()
        do {
            _ = try await client.perform { c in try c.undo() }
            if answeredCount > 0 { answeredCount -= 1 }
            let restored = history.popLast()
            await loadNext(reuse: restored)
        } catch let e as BackendError where e.isUndoEmpty {
            history.removeAll()
            await loadNext(reuse: nil)
        } catch {
            phase = .error("\(error)")
        }
    }

    func replayAudio() {
        if answerRevealed { playAnswerAudio() } else { playQuestionAudio() }
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
            pushHistory(cur)
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
