import SwiftUI

/// Scope helpers for resetting study progress. Pure, so they can be tested
/// without a collection.
enum ResetScope {
    /// 1-based inclusive range over `ids`, clamped to what exists. Empty when
    /// the range is inverted or falls outside the deck.
    static func slice(_ ids: [Int64], from: Int, to: Int) -> [Int64] {
        guard !ids.isEmpty else { return [] }
        let lo = max(from, 1)
        let hi = min(to, ids.count)
        guard lo <= hi else { return [] }
        return Array(ids[(lo - 1)..<hi])
    }

    /// A `deck:"…"` term. `\` and `"` are the only characters that can break out
    /// of the quoted name.
    static func quoted(_ deckName: String) -> String {
        let escaped = deckName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "deck:\"\(escaped)\""
    }

    /// Search matching the studied (non-new) cards of every named deck, or nil
    /// when nothing is selected. A parent deck covers its children.
    static func studiedSearch(deckNames: [String]) -> String? {
        guard !deckNames.isEmpty else { return nil }
        let terms = deckNames.map(quoted).joined(separator: " or ")
        return deckNames.count == 1 ? "\(terms) -is:new" : "(\(terms)) -is:new"
    }
}

/// Send studied cards back to new: the whole deck, chosen chapters, or a
/// numbered range in 単語帳 order. Never-studied cards are left untouched so
/// their place in the new queue is preserved.
struct ResetScopeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let deckID: Int64
    let deckName: String

    private enum Mode: Int, Hashable { case all, chapters, range }

    @State private var mode: Mode = .all
    @State private var picked: Set<String> = []
    @State private var fromText = "1"
    @State private var toText = ""
    @State private var orderedIDs: [Int64] = []
    @State private var studiedIDs: Set<Int64> = []
    @State private var chapterCount = 0
    @State private var loading = true
    @State private var busy = false
    @State private var confirm = false
    @State private var error: String?

    private var chapters: [DeckTreeNode] {
        model.node(for: deckID)?.children.filter { !$0.filtered } ?? []
    }
    private var from: Int { Int(fromText) ?? 1 }
    private var to: Int { Int(toText) ?? orderedIDs.count }

    /// Re-runs the chapter count whenever the selection (or the mode) changes.
    private var chapterKey: String { "\(mode.rawValue)|" + picked.sorted().joined(separator: "\n") }

    private var targetCount: Int {
        switch mode {
        case .all: return studiedIDs.count
        case .chapters: return chapterCount
        case .range: return ResetScope.slice(orderedIDs, from: from, to: to).filter { studiedIDs.contains($0) }.count
        }
    }

    private var scopeLabel: String {
        switch mode {
        case .all: return "\(shortName(deckName)) 全部"
        case .chapters: return picked.isEmpty ? "章が選ばれていません" : "\(picked.count) 章"
        case .range: return "\(max(from, 1)) 〜 \(min(to, orderedIDs.count)) 枚目"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("どこを戻すか") {
                    Picker("範囲", selection: $mode) {
                        Text("このデッキ全部").tag(Mode.all)
                        if !chapters.isEmpty { Text("章を選ぶ").tag(Mode.chapters) }
                        Text("番号で指定").tag(Mode.range)
                    }
                    .pickerStyle(.inline).labelsHidden()
                }

                if mode == .chapters {
                    Section("章") {
                        ForEach(chapters, id: \.deckID) { ch in
                            Button {
                                if picked.contains(ch.name) { picked.remove(ch.name) } else { picked.insert(ch.name) }
                            } label: {
                                HStack {
                                    Text(chapterLabel(ch.name)).foregroundStyle(Theme.ink)
                                    Spacer()
                                    Text("\(ch.totalIncludingChildren) 枚").font(.caption).foregroundStyle(Theme.gray1)
                                    Image(systemName: picked.contains(ch.name) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(picked.contains(ch.name) ? Theme.ink : Theme.gray2)
                                }
                            }
                        }
                        Text("章を選ぶと、その中の節も一緒に戻ります。")
                            .font(.caption2).foregroundStyle(Theme.gray2)
                    }
                }

                if mode == .range {
                    Section("番号(単語帳の並び)") {
                        HStack {
                            TextField("1", text: $fromText).keyboardType(.numberPad)
                            Text("枚目 〜").foregroundStyle(Theme.gray1)
                            TextField("\(orderedIDs.count)", text: $toText).keyboardType(.numberPad)
                            Text("枚目").foregroundStyle(Theme.gray1)
                        }
                        Text("全 \(orderedIDs.count) 枚。ノートの追加順で数えます(「章に分ける」と同じ並び)。")
                            .font(.caption2).foregroundStyle(Theme.gray2)
                    }
                }

                Section {
                    if loading {
                        Text("数えています…").font(.footnote).foregroundStyle(Theme.gray1)
                    } else {
                        Text("学習済み \(targetCount) 枚を新規に戻します").font(.footnote)
                        Text("未学習のカードは動かしません。復習の予定と間隔が消え、最初から出題されます。履歴は残り、デッキ一覧の履歴メニューから取り消せます。")
                            .font(.caption2).foregroundStyle(Theme.gray2)
                    }
                }

                if let error { Text(error).font(.footnote).foregroundStyle(Theme.gray1) }
            }
            .navigationTitle("学習をリセット")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("リセット") { confirm = true }
                        .disabled(busy || loading || targetCount == 0)
                }
            }
            .task { await load() }
            .task(id: chapterKey) { await countChapters() }
            .confirmationDialog("\(targetCount) 枚を新規に戻しますか?", isPresented: $confirm, titleVisibility: .visible) {
                Button("新規に戻す(履歴は残ります)", role: .destructive) { Task { await run() } }
            } message: {
                Text(scopeLabel)
            }
        }
    }

    private func chapterLabel(_ full: String) -> String {
        let tail = full.components(separatedBy: "::").dropFirst().joined(separator: "·")
        return tail.isEmpty ? shortName(full) : tail
    }

    private func load() async {
        guard let client = model.client else { loading = false; return }
        let n = deckName
        do {
            let (all, done) = try await client.perform { c -> ([Int64], [Int64]) in
                let all = try c.searchCards(ResetScope.quoted(n), orderSQL: "n.id asc, c.ord asc")
                let done = try c.searchCards(ResetScope.quoted(n) + " -is:new")
                return (all, done)
            }
            orderedIDs = all
            studiedIDs = Set(done)
            if toText.isEmpty { toText = "\(all.count)" }
        } catch {
            self.error = "\(error)"
        }
        loading = false
    }

    private func countChapters() async {
        guard mode == .chapters else { return }
        guard let client = model.client, let search = ResetScope.studiedSearch(deckNames: picked.sorted()) else {
            chapterCount = 0
            return
        }
        chapterCount = (try? await client.perform { c in try c.searchCards(search).count }) ?? 0
    }

    private func targets() async throws -> [Int64] {
        switch mode {
        case .all:
            return orderedIDs.filter { studiedIDs.contains($0) }
        case .range:
            return ResetScope.slice(orderedIDs, from: from, to: to).filter { studiedIDs.contains($0) }
        case .chapters:
            guard let client = model.client, let search = ResetScope.studiedSearch(deckNames: picked.sorted()) else { return [] }
            return try await client.perform { c in try c.searchCards(search) }
        }
    }

    private func run() async {
        guard let client = model.client else { return }
        busy = true
        defer { busy = false }
        do {
            let ids = try await targets()
            guard !ids.isEmpty else { dismiss(); return }
            try await client.perform { c in try c.forgetCards(ids) }
            await model.refreshDecks()
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}
