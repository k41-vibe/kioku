import Foundation

/// A card laid out by Kioku from the note's fields (instead of the deck's HTML
/// template): word, example, meaning, example translation, audio, extras.
struct NativeCard: Equatable {
    struct Audio: Equatable {
        var label: String
        var tag: Anki_CardRendering_AVTag
    }

    var word: String
    var reading: String = ""            // e.g. 品詞 / pronunciation shown under the word
    var example: String = ""
    var meaning: [String] = []
    var exampleMeaning: String = ""
    var extras: [(String, String)] = []
    var wordAudio: [Audio] = []
    var exampleAudio: [Audio] = []

    static func == (a: NativeCard, b: NativeCard) -> Bool {
        a.word == b.word && a.example == b.example && a.meaning == b.meaning && a.exampleMeaning == b.exampleMeaning
            && a.extras.map { $0.0 + $0.1 } == b.extras.map { $0.0 + $0.1 } && a.wordAudio == b.wordAudio && a.exampleAudio == b.exampleAudio
    }

    var questionAudio: [Anki_CardRendering_AVTag] { wordAudio.map { $0.tag } }
    var answerAudio: [Anki_CardRendering_AVTag] { exampleAudio.map { $0.tag } }

    // MARK: - Classification

    private static let wordNames = ["単語", "word", "見出し", "英単語", "term", "綴り", "spelling"]
    private static let exampleNames = ["例文", "example", "sentence", "文例", "用例"]
    private static let exampleMeaningNames = ["例文意味", "例文訳", "例文の意味", "例文和訳", "sentence meaning", "example meaning", "example translation", "例訳"]
    private static let readingNames = ["品詞", "発音", "読み", "reading", "pronunciation", "ipa", "pos", "part of speech"]
    private static let skipNames = ["id", "tags", "pic", "picture", "image", "画像", "番号", "no", "num"]

    private static let avPattern = try! NSRegularExpression(pattern: #"\[sound:[^\]]+\]|\[anki:tts[^\]]*\].*?\[/anki:tts\]"#, options: [.dotMatchesLineSeparators])
    /// Remove [sound:...] / tts tags (strip_html leaves them in place).
    static func withoutAV(_ s: String) -> String {
        let ns = s as NSString
        return avPattern.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    private static func lower(_ s: String) -> String { s.lowercased() }
    private static func matches(_ name: String, _ list: [String]) -> Bool {
        let n = lower(name)
        return list.contains { n.contains($0) }
    }

    /// True for a bare identifier a deck sorts by — "p1q5_0002", "0049", "p1q5" —
    /// so it is never mistaken for the headword. A real word or phrase is false:
    /// the value must be one alphanumeric token containing a digit, and either be
    /// all digits, carry an underscore, or alternate letters and digits twice.
    static func looksLikeCode(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 32 else { return false }
        guard t.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        if t.allSatisfy({ $0.isNumber }) { return true }
        if t.contains("_") { return t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }
        var runs = 0
        var prevIsDigit: Bool?
        for ch in t {
            guard ch.isLetter || ch.isNumber else { return false }
            if ch.isNumber != prevIsDigit { runs += 1; prevIsDigit = ch.isNumber }
        }
        return runs >= 4
    }

    /// Build from a note. `strip` removes HTML (keeps newlines). Returns nil when
    /// there is not enough structure to make a sensible layout.
    static func build(note: Anki_Notes_Note, notetype: Anki_Notetypes_Notetype, memoField: String,
                      strip: (String) -> String, avTags: (String) -> [Anki_CardRendering_AVTag]) -> NativeCard? {
        let names = notetype.fields.map { $0.name }
        guard !names.isEmpty, note.fields.count >= 2 else { return nil }
        let sortIdx = min(Int(notetype.config.sortFieldIdx), names.count - 1)

        var card = NativeCard(word: "")
        var used = Set<Int>()

        func text(_ i: Int) -> String { i < note.fields.count ? note.fields[i] : "" }
        func plain(_ i: Int) -> String { withoutAV(strip(text(i))).trimmingCharacters(in: .whitespacesAndNewlines) }

        // Audio: any field carrying [sound:] tags. Word audio = names mentioning 単語/word/audio/sound without 例文.
        for (i, name) in names.enumerated() {
            let tags = avTags(text(i))
            guard !tags.isEmpty else { continue }
            let isExample = matches(name, exampleNames)
            for t in tags {
                let a = Audio(label: name, tag: t)
                if isExample { card.exampleAudio.append(a) } else { card.wordAudio.append(a) }
            }
            // A field that is *only* audio is consumed here.
            if plain(i).isEmpty { used.insert(i) }
        }

        // Word: a field named 単語/word wins. Otherwise the sort field, unless it
        // holds a bare id like "p1q5_0002" — then the word is picked up from the
        // first leftover field below, so every later slot shifts back into place.
        // Remaining lines of the word field become the example when there is no
        // dedicated example field (鉄壁 style "word<br>sentence").
        let namedWord = names.indices.first { i in
            !used.contains(i) && matches(names[i], wordNames) && !plain(i).isEmpty
                && !matches(names[i], exampleNames) && !matches(names[i], exampleMeaningNames)
                && !matches(names[i], readingNames)
        }
        let wordIdx: Int? = namedWord ?? (looksLikeCode(plain(sortIdx)) ? nil : sortIdx)
        used.insert(sortIdx)    // an id sort field is never shown on its own
        var wordRest = ""
        if let wordIdx {
            let wordLines = plain(wordIdx).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let first = wordLines.first {
                card.word = first
                used.insert(wordIdx)
                wordRest = wordLines.dropFirst().joined(separator: "\n")
            }
        }

        for (i, name) in names.enumerated() where !used.contains(i) {
            if name == memoField { used.insert(i); continue }
            if matches(name, skipNames) { used.insert(i); continue }
            let v = plain(i)
            if v.isEmpty { used.insert(i); continue }
            if matches(name, exampleMeaningNames) {
                if card.exampleMeaning.isEmpty { card.exampleMeaning = v; used.insert(i) }
            } else if matches(name, exampleNames) {
                if card.example.isEmpty { card.example = v; used.insert(i) }
            } else if matches(name, readingNames) {
                if card.reading.isEmpty { card.reading = v; used.insert(i) }
            }
        }
        if card.example.isEmpty, !wordRest.isEmpty { card.example = wordRest }

        // Meaning = the first remaining field(s) that look like an answer; the rest are extras.
        // When the sort field was an id, the first leftover is the headword instead.
        for (i, name) in names.enumerated() where !used.contains(i) {
            let v = plain(i)
            if v.isEmpty { continue }
            if card.word.isEmpty {
                card.word = v.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? v
                used.insert(i)
                continue
            }
            if card.meaning.isEmpty {
                // Back/裏面 style fields may pack several lines: keep the first block as the meaning.
                let lines = v.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                card.meaning = [lines.first ?? v]
                if lines.count > 1 { card.extras.append((name, lines.dropFirst().joined(separator: "\n"))) }
            } else {
                card.extras.append((name, v))
            }
            used.insert(i)
        }
        guard !card.word.isEmpty else { return nil }
        guard !card.meaning.isEmpty || !card.example.isEmpty else { return nil }
        return card
    }
}
