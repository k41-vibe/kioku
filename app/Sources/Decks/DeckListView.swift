import SwiftUI
import UniformTypeIdentifiers

/// Home screen: hierarchical deck list with the day's counts, import button.
struct DeckListView: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false
    @State private var showStats = false
    @State private var showSettings = false
    @State private var renaming: DeckTreeNode?
    @State private var renameText = ""
    @State private var deleting: DeckTreeNode?

    var body: some View {
        NavigationStack {
            Group {
                if let tree = model.deckTree, !tree.children.isEmpty {
                    List {
                        if !model.pendingPackages.isEmpty { pendingSection }
                        ForEach(tree.children, id: \.deckID) { node in
                            DeckRows(node: node, onRename: { renaming = $0; renameText = shortName($0.name) }, onDelete: { deleting = $0 })
                        }
                        Section {
                            Text("学習画面: タップで答え、上スワイプ=普通、左スワイプ=もう一度")
                                .font(.caption2).foregroundStyle(Theme.gray2)
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .refreshable { await model.refreshDecks(); model.scanDocuments() }
                } else {
                    ScrollView {
                        emptyState.frame(minHeight: 520)
                    }
                    .refreshable { await model.refreshDecks(); model.scanDocuments() }
                }
            }
            .background(Theme.paper)
            .navigationTitle("Kioku")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showStats = true } label: { Image(systemName: "chart.bar") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !model.undoLabel.isEmpty {
                        Button { Task { await model.undo() } } label: { Image(systemName: "arrow.uturn.backward") }
                    }
                    Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: Int64.self) { deckID in
                DeckDetailView(deckID: deckID)
            }
            .sheet(isPresented: $showStats) { StatsView(search: "") }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { Task { await model.importPackage(from: url) } }
                case .failure(let error):
                    model.errorMessage = "ファイルを選べませんでした: \(error.localizedDescription)"
                }
            }
            .overlay {
                if model.isImporting {
                    ZStack {
                        Theme.paper.opacity(0.7).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("取り込み中…").font(.footnote).foregroundStyle(Theme.gray1)
                        }
                    }
                }
            }
            .alert("取り込み完了", isPresented: Binding(get: { model.importSummary != nil }, set: { if !$0 { model.importSummary = nil } })) {
                Button("OK") { model.importSummary = nil }
            } message: {
                if let s = model.importSummary { Text("\(s.fileName)\n\(s.text)") }
            }
            .alert("エラー", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .alert("デッキ名を変更", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("名前", text: $renameText)
                Button("変更") {
                    if let node = renaming {
                        let parent: String
                        if let r = node.name.range(of: "::", options: .backwards) {
                            parent = String(node.name[..<r.upperBound])
                        } else {
                            parent = ""
                        }
                        Task { await model.renameDeck(node.deckID, to: parent + renameText) }
                    }
                    renaming = nil
                }
                Button("キャンセル", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("「\(deleting.map { shortName($0.name) } ?? "")」を削除しますか?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("削除(カードも消えます)", role: .destructive) {
                    if let d = deleting { Task { await model.deleteDeck(d.deckID) } }
                    deleting = nil
                }
            }
        }
    }

    private var pendingSection: some View {
        Section {
            ForEach(model.pendingPackages, id: \.path) { url in
                HStack {
                    Image(systemName: "doc.zipper").foregroundStyle(Theme.gray1)
                    Text(url.lastPathComponent).font(.footnote).lineLimit(1)
                    Spacer()
                }
            }
            Button {
                Task { await model.importPendingPackages() }
            } label: {
                Label("上の \(model.pendingPackages.count) 個を取り込む", systemImage: "square.and.arrow.down")
            }
            .disabled(model.isImporting)
        } header: {
            Text("Documents に見つかったパッケージ")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "rectangle.stack").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.gray2)
            Text("デッキがありません").font(.headline)
            Text(".apkg を取り込むと、ここに出ます。\n共有シートから Kioku を選ぶか、右上の取り込みボタンで選択してください。")
                .font(.footnote).foregroundStyle(Theme.gray1).multilineTextAlignment(.center).padding(.horizontal, 32)
            Button { showImporter = true } label: {
                Text(".apkg を取り込む").padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(Theme.paper)
            }
            if !model.pendingPackages.isEmpty {
                Button {
                    Task { await model.importPendingPackages() }
                } label: {
                    Text("Documents の \(model.pendingPackages.count) 個を取り込む").padding(.horizontal, 20).padding(.vertical, 12)
                        .background(Theme.paper2, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(Theme.ink)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.gray3))
                }
            } else {
                Text("うまくいかないときは、ファイル App でこのアプリの Documents フォルダに .apkg を置いてから画面を引き下げて更新してください。")
                    .font(.caption2).foregroundStyle(Theme.gray2).multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            Spacer()
            Text("core: anki 26.08.1 / bridge \(AnkiBackend.bridgeVersion)").font(.caption2).foregroundStyle(Theme.gray2).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

func shortName(_ full: String) -> String {
    full.components(separatedBy: "::").last ?? full
}

/// Recursive deck rows (indent by level, collapsible).
struct DeckRows: View {
    @Environment(AppModel.self) private var model
    let node: DeckTreeNode
    let onRename: (DeckTreeNode) -> Void
    let onDelete: (DeckTreeNode) -> Void

    var body: some View {
        NavigationLink(value: node.deckID) {
            HStack(spacing: 8) {
                if !node.children.isEmpty {
                    Button {
                        Task { await model.setCollapsed(node.deckID, !node.collapsed); await model.refreshDecks() }
                    } label: {
                        Image(systemName: node.collapsed ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.gray1).frame(width: 18)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortName(node.name)).font(.body).foregroundStyle(Theme.ink).lineLimit(1)
                    if node.filtered {
                        Text("フィルタ").font(.caption2).foregroundStyle(Theme.gray2)
                    }
                }
                Spacer()
                HStack(spacing: 10) {
                    CountLabel(label: "新", value: node.newCount, emphasized: true)
                    CountLabel(label: "学", value: node.learnCount, emphasized: true)
                    CountLabel(label: "復", value: node.reviewCount, emphasized: true)
                }
            }
            .padding(.leading, CGFloat(max(Int(node.level) - 1, 0)) * 18)
            .padding(.vertical, 4)
        }
        .listRowBackground(Theme.paper)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { onDelete(node) } label: { Label("削除", systemImage: "trash") }
            Button { onRename(node) } label: { Label("名前", systemImage: "pencil") }.tint(Theme.gray1)
        }
        if !node.collapsed {
            ForEach(node.children, id: \.deckID) { child in
                DeckRows(node: child, onRename: onRename, onDelete: onDelete)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mono = true
    @State private var checkResult: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section("見た目") {
                    Toggle("アプリの見た目を優先(デッキの色指定を無視)", isOn: $mono)
                        .onChange(of: mono) { _, v in model.forceMonochrome = v }
                }
                Section("メンテナンス") {
                    Button {
                        busy = true
                        Task {
                            let problems = (try? await model.client?.perform { c in try c.checkDatabase() }) ?? []
                            checkResult = problems.isEmpty ? "問題は見つかりませんでした" : problems.joined(separator: "\n")
                            busy = false
                            await model.refreshDecks()
                        }
                    } label: { Label("データベースを確認", systemImage: "stethoscope") }
                    .disabled(busy)
                    Button {
                        busy = true
                        Task {
                            let ok = (try? await model.client?.perform { c in try c.createBackup(force: true) }) ?? false
                            checkResult = ok ? "バックアップを作成しました" : "バックアップは作成されませんでした"
                            busy = false
                        }
                    } label: { Label("今すぐバックアップ", systemImage: "externaldrive") }
                    .disabled(busy)
                    if let p = model.client?.paths.root.path {
                        Text(p).font(.caption2).foregroundStyle(Theme.gray2).textSelection(.enabled)
                    }
                }
                Section("取り込みの記録") {
                    Text("ファイル App で置く場所: \(CollectionPaths.documents.path)").font(.caption2).foregroundStyle(Theme.gray2).textSelection(.enabled)
                    if model.importLog.isEmpty {
                        Text("まだ記録はありません").font(.caption2).foregroundStyle(Theme.gray2)
                    } else {
                        ForEach(Array(model.importLog.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption2.monospaced()).foregroundStyle(Theme.gray1).textSelection(.enabled)
                        }
                    }
                }
                Section("このアプリ") {
                    Text("Kioku は Anki の Rust コア(rslib)をそのまま組み込んでいます。スケジューリング(FSRS / SM-2)、.apkg 取り込み、カード描画、統計はすべて本家と同じコードで動きます。")
                        .font(.footnote).foregroundStyle(Theme.gray1)
                    Text("anki 26.08.1 · bridge \(AnkiBackend.bridgeVersion) · AGPL-3.0").font(.caption2).foregroundStyle(Theme.gray2)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .onAppear { mono = model.forceMonochrome }
            .alert("結果", isPresented: Binding(get: { checkResult != nil }, set: { if !$0 { checkResult = nil } })) {
                Button("OK") { checkResult = nil }
            } message: { Text(checkResult ?? "") }
        }
    }
}
