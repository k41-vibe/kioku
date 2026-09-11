import SwiftUI

/// Deck overview: counts for the day, study, drill (周回), chapter split.
struct DeckDetailView: View {
    @Environment(AppModel.self) private var model
    let deckID: Int64
    @State private var session: ReviewSession?
    @State private var showDrillSetup = false
    @State private var showSplit = false
    @State private var showStats = false
    @State private var showPlan = false
    @State private var confirmReset = false
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
                Section("ペース") {
                    if let status = model.planStatuses[deckID] {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(status.plan.label + (status.currentChapter.map { " · 今は \($0.name.components(separatedBy: "::").dropFirst().joined(separator: "·"))" } ?? ""))
                                .font(.footnote)
                            Text("今日の新規 \(status.todayNew) 枚 · 導入 \(status.introduced)/\(status.totalInScope)")
                                .font(.caption).foregroundStyle(Theme.gray1)
                        }
                        Button { showPlan = true } label: { Label("ペースを変える / やめる", systemImage: "slider.horizontal.3") }
                    } else {
                        Button { showPlan = true } label: { Label("ペースを決める(1章/週 など)", systemImage: "calendar") }
                        Text("章ごと、または単語数で毎日の新規枚数を自動で決めます。復習は忘却曲線どおりです。")
                            .font(.caption2).foregroundStyle(Theme.gray2)
                    }
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
                    if !node.filtered {
                        Button { showSplit = true } label: {
                            Label(node.children.isEmpty ? "章に分ける" : "各章を節に分ける", systemImage: "square.split.2x1")
                        }
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
                    Button(role: .destructive) { confirmReset = true } label: { Label("学習をリセット(全部新規に戻す)", systemImage: "arrow.counterclockwise") }
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
        .confirmationDialog("「\(shortName(name))」の全カードを新規に戻しますか?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("新規に戻す(履歴は残ります)", role: .destructive) {
                busy = true
                Task {
                    let n = name
                    do {
                        try await model.client?.perform { c in
                            let ids = try c.searchCards("deck:\"\(n)\"")
                            if !ids.isEmpty { try c.forgetCards(ids) }
                        }
                    } catch { model.errorMessage = "\(error)" }
                    await model.refreshDecks()
                    busy = false
                }
            }
        } message: {
            Text("復習の予定と間隔が消え、最初から出題されます。取り消しはデッキ一覧の履歴メニューからできます。")
        }
        .sheet(isPresented: $showPlan) {
            PlanSetupView(deckID: deckID, deckName: name,
                          hasChapters: node.map { PlanEngine.hasLevel($0, 1) } ?? false,
                          hasSections: node.map { PlanEngine.hasLevel($0, 2) } ?? false)
        }
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

    /// Existing chapters (direct subdecks). When present we split each of them into sections.
    private var existingChapters: [DeckTreeNode] {
        model.node(for: deckID)?.children.filter { !$0.filtered } ?? []
    }
    private var sectionMode: Bool { !existingChapters.isEmpty }

    var chapters: Int { total == 0 ? 0 : (total + perChapter - 1) / perChapter }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if sectionMode {
                        Stepper("1節あたり \(perChapter) 枚", value: $perChapter, in: 5...200, step: 5)
                        let avg = existingChapters.isEmpty ? 0 : Int(existingChapters.reduce(0) { $0 + Int($1.totalIncludingChildren) }) / existingChapters.count
                        Text("\(existingChapters.count) 章(平均 \(avg) 枚)→ 各章を約 \(max((avg + perChapter - 1) / max(perChapter, 1), 1)) 節に(\(shortName(deckName))::01::01 …)").font(.footnote).foregroundStyle(Theme.gray1)
                    } else {
                        Stepper("1章あたり \(perChapter) 枚", value: $perChapter, in: 20...500, step: 10)
                        Text("全 \(total) 枚 → \(chapters) 章(\(shortName(deckName))::01 …)").font(.footnote).foregroundStyle(Theme.gray1)
                    }
                }
                Section {
                    Text(sectionMode
                         ? "各章の中を、ノートの追加順で節に区切ります。すでに節がある章はそのままです。"
                         : "ノートの追加順(単語帳の並び)で区切ります。同じノートのカードは同じ章に入ります。元に戻すには章デッキを親デッキ名に改名して統合してください。")
                        .font(.caption2).foregroundStyle(Theme.gray2)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.gray1) }
            }
            .navigationTitle(sectionMode ? "節に分ける" : "章に分ける")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("実行") { Task { await split() } }.disabled(busy || (total == 0 && !sectionMode)) }
            }
            .task {
                let name = deckName
                if sectionMode { perChapter = 20 }
                total = (try? await model.client?.perform { c in try c.searchCards("deck:\"\(name)\"", orderSQL: "n.id asc, c.ord asc").count }) ?? 0
            }
        }
    }

    private func split() async {
        guard let client = model.client else { return }
        busy = true
        defer { busy = false }
        let size = perChapter
        // Targets: the deck itself (chapter mode) or each chapter without sections (section mode).
        let targets: [(name: String, pad: Int)] = sectionMode
            ? existingChapters.filter { $0.children.isEmpty }.map { ($0.name, 2) }
            : [(deckName, 2)]
        do {
            try await client.perform { c in
                for target in targets {
                    let ids = try c.searchCards("deck:\"\(target.name)\"", orderSQL: "n.id asc, c.ord asc")
                    var part = 1
                    var index = 0
                    while index < ids.count {
                        let end = min(index + size, ids.count)
                        let partName = target.name + "::" + String(format: "%0\(target.pad)d", part)
                        let did: Int64
                        if let existing = try c.deckID(named: partName) { did = existing } else { did = try c.addDeck(named: partName) }
                        _ = try c.setDeck(cardIDs: Array(ids[index..<end]), deckID: did)
                        part += 1
                        index = end
                    }
                }
            }
            await model.refreshDecks()
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}
