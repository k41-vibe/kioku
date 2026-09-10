import SwiftUI

/// Deck overview: counts for the day, study, drill (周回), chapter split.
struct DeckDetailView: View {
    @Environment(AppModel.self) private var model
    let deckID: Int64
    @State private var session: ReviewSession?
    @State private var showDrillSetup = false
    @State private var showSplit = false
    @State private var showStats = false
    @State private var extendNew = 10
    @State private var busy = false
    @State private var description: String = ""

    private var node: DeckTreeNode? { model.node(for: deckID) }
    private var name: String { model.deckName(deckID) }

    var body: some View {
        List {
            if let node {
                Section {
                    HStack(spacing: 0) {
                        stat("新規", node.newCount)
                        stat("学習中", node.learnCount)
                        stat("復習", node.reviewCount)
                    }
                    .listRowBackground(Theme.paper)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("全 \(node.totalIncludingChildren) 枚").font(.footnote).foregroundStyle(Theme.gray1)
                        if !description.isEmpty {
                            Text(description).font(.footnote).foregroundStyle(Theme.gray1)
                        }
                    }
                    .listRowBackground(Theme.paper)
                }
                Section {
                    Button {
                        if let client = model.client {
                            session = ReviewSession(client: client, deckID: deckID, deckName: name, mode: .normal)
                        }
                    } label: {
                        Text(node.newCount + node.learnCount + node.reviewCount > 0 ? "学習を始める" : "今日の分は終了(それでも開く)")
                            .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(Theme.paper)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                Section("周回") {
                    Button {
                        showDrillSetup = true
                    } label: {
                        Label("この範囲を周回する", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Text("予定に影響させず、範囲内のカードを全部正解するまで繰り返します。")
                        .font(.caption2).foregroundStyle(Theme.gray2)
                }
                Section("今日だけ") {
                    Stepper("新規カードを \(extendNew) 枚追加", value: $extendNew, in: 5...200, step: 5)
                    Button("追加する") {
                        busy = true
                        Task {
                            _ = try? await model.client?.perform { c in try c.extendLimits(deckID: deckID, newDelta: Int32(extendNew), reviewDelta: 0) }
                            await model.refreshDecks()
                            busy = false
                        }
                    }
                    .disabled(busy)
                }
                Section("整理") {
                    if node.children.isEmpty && !node.filtered {
                        Button { showSplit = true } label: { Label("章に分ける", systemImage: "square.split.2x1") }
                    }
                    Button {
                        busy = true
                        Task {
                            _ = try? await model.client?.perform { c in try c.unburyDeck(deckID) }
                            await model.refreshDecks()
                            busy = false
                        }
                    } label: { Label("埋めたカードを戻す", systemImage: "tray.and.arrow.up") }
                    Button { showStats = true } label: { Label("このデッキの統計", systemImage: "chart.bar") }
                }
            } else {
                Text("デッキが見つかりません").foregroundStyle(Theme.gray1)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .navigationTitle(shortName(name))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDescription() }
        .fullScreenCover(item: $session) { s in
            NavigationStack { ReviewerView(session: s) }
        }
        .sheet(isPresented: $showDrillSetup) {
            DrillSetupView(deckID: deckID, deckName: name) { s in session = s }
        }
        .sheet(isPresented: $showSplit) {
            ChapterSplitView(deckID: deckID, deckName: name)
        }
        .sheet(isPresented: $showStats) { StatsView(search: "deck:\"\(name)\"") }
    }

    private func stat(_ label: String, _ value: UInt32) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.monospacedDigit().weight(value > 0 ? .semibold : .regular)).foregroundStyle(value > 0 ? Theme.ink : Theme.gray2)
            Text(label).font(.caption2).foregroundStyle(Theme.gray1)
        }
        .frame(maxWidth: .infinity)
    }

    private func loadDescription() async {
        guard let client = model.client else { return }
        if let d = try? await client.perform({ c in try c.deck(deckID) }), case .normal(let n)? = d.kind {
            description = n.description_p
        }
    }
}

extension ReviewSession: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// Choose options and start a preview drill over this deck.
struct DrillSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let deckID: Int64
    let deckName: String
    let onStart: (ReviewSession) -> Void
    @State private var order: Anki_Decks_Deck.Filtered.SearchTerm.Order = .added
    @State private var includeNew = true
    @State private var limit = 500
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("範囲") {
                    Text(deckName).foregroundStyle(Theme.gray1)
                    Toggle("未学習カードも含める", isOn: $includeNew)
                    Stepper("上限 \(limit) 枚", value: $limit, in: 20...2000, step: 20)
                }
                Section("順番") {
                    Picker("順番", selection: $order) {
                        Text("追加順").tag(Anki_Decks_Deck.Filtered.SearchTerm.Order.added)
                        Text("ランダム").tag(Anki_Decks_Deck.Filtered.SearchTerm.Order.random)
                        Text("失敗が多い順").tag(Anki_Decks_Deck.Filtered.SearchTerm.Order.lapses)
                        Text("覚えていない順").tag(Anki_Decks_Deck.Filtered.SearchTerm.Order.retrievabilityAscending)
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                Section {
                    Text("周回中の評価は本番のスケジュールに記録されません。「もう一度」は 1 分後に再登場、「普通」「簡単」で抜けます。")
                        .font(.caption2).foregroundStyle(Theme.gray2)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.gray1) }
            }
            .navigationTitle("周回")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("開始") { Task { await start() } }.disabled(busy)
                }
            }
        }
    }

    private func start() async {
        guard let client = model.client else { return }
        busy = true
        defer { busy = false }
        let search = "deck:\"\(deckName)\"" + (includeNew ? "" : " -is:new")
        let title = "周回: \(shortName(deckName))"
        let limitValue = UInt32(limit)
        let orderValue = order
        do {
            let fid = try await client.perform { c in
                if let old = try c.deckID(named: title) { _ = try c.removeDecks([old]) }
                return try c.createFilteredDeck(name: title, search: search, limit: limitValue, order: orderValue,
                                                reschedule: false, previewAgainSecs: 60, previewHardSecs: 600, previewGoodSecs: 0)
            }
            let s = ReviewSession(client: client, deckID: deckID, deckName: deckName, mode: .drill(filteredDeckID: fid, title: title))
            dismiss()
            onStart(s)
        } catch {
            self.error = "\(error)"
        }
    }
}

/// Split a flat deck into numbered chapter subdecks by note order.
struct ChapterSplitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let deckID: Int64
    let deckName: String
    @State private var perChapter = 100
    @State private var total = 0
    @State private var busy = false
    @State private var error: String?

    var chapters: Int { total == 0 ? 0 : (total + perChapter - 1) / perChapter }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("1章あたり \(perChapter) 枚", value: $perChapter, in: 20...500, step: 10)
                    Text("全 \(total) 枚 → \(chapters) 章(\(shortName(deckName))::01 …)").font(.footnote).foregroundStyle(Theme.gray1)
                }
                Section {
                    Text("ノートの追加順(単語帳の並び)で区切ります。同じノートのカードは同じ章に入ります。元に戻すには章デッキを親デッキ名に改名して統合してください。")
                        .font(.caption2).foregroundStyle(Theme.gray2)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.gray1) }
            }
            .navigationTitle("章に分ける")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("実行") { Task { await split() } }.disabled(busy || total == 0) }
            }
            .task {
                let name = deckName
                total = (try? await model.client?.perform { c in try c.searchCards("deck:\"\(name)\"", orderSQL: "n.id asc, c.ord asc").count }) ?? 0
            }
        }
    }

    private func split() async {
        guard let client = model.client else { return }
        busy = true
        defer { busy = false }
        let name = deckName
        let size = perChapter
        do {
            try await client.perform { c in
                let ids = try c.searchCards("deck:\"\(name)\"", orderSQL: "n.id asc, c.ord asc")
                var chapter = 1
                var index = 0
                while index < ids.count {
                    let end = min(index + size, ids.count)
                    let chapterName = name + "::" + String(format: "%02d", chapter)
                    let did: Int64
                    if let existing = try c.deckID(named: chapterName) { did = existing } else { did = try c.addDeck(named: chapterName) }
                    _ = try c.setDeck(cardIDs: Array(ids[index..<end]), deckID: did)
                    chapter += 1
                    index = end
                }
            }
            await model.refreshDecks()
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}
