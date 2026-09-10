import SwiftUI

/// Reel-style study screen: one card fills the screen, tap to flip, swipe up
/// for Good / left for Again, with all four Anki buttons along the bottom.
struct ReviewerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var model
    @State var session: ReviewSession
    @State private var showCardInfo = false
    @State private var cardStats: Anki_Stats_CardStatsResponse?
    @State private var confirmSuspend = false

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            content
            overlayChrome
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(false)
        .task {
            session.night = colorScheme == .dark
            await session.start()
        }
        .onChange(of: colorScheme) { _, new in session.night = new == .dark }
        .onDisappear {
            Task {
                await session.end()
                await model.refreshDecks()
            }
        }
        .sheet(isPresented: $showCardInfo) {
            CardInfoView(stats: cardStats)
        }
        .alert("エラー", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
        .confirmationDialog("このカードを保留しますか?", isPresented: $confirmSuspend, titleVisibility: .visible) {
            Button("保留する", role: .destructive) { Task { await session.suspendCard() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading where session.html.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .finished:
            finishedView
        case .error(let msg):
            VStack(spacing: 12) {
                Text("問題が起きました").font(.headline)
                Text(msg).font(.footnote).foregroundStyle(Theme.gray1).multilineTextAlignment(.center).padding()
                Button("戻る") { dismiss() }.buttonStyle(.bordered)
            }
        default:
            CardWebView(html: session.html, mediaFolder: session.client.paths.media, controller: session.web) { event in
                handle(event)
            }
            .ignoresSafeArea(edges: .bottom)
            .opacity(session.phase == .loading ? 0.5 : 1)
        }
    }

    private func handle(_ event: CardWebEvent) {
        switch event {
        case .tap(let typed):
            if session.phase == .question { Task { await session.showAnswer(typed: typed) } }
        case .showAnswer(let typed):
            if session.phase == .question { Task { await session.showAnswer(typed: typed) } }
        case .play(let side, let idx):
            session.play(side: side, index: idx)
        case .swipe(let dir):
            guard session.phase == .answer else {
                if session.phase == .question, dir == .up { Task { await session.showAnswer() } }
                return
            }
            if dir == .up { Task { await session.answer(.good) } }
            else if dir == .left { Task { await session.answer(.again) } }
        case .loaded:
            break
        }
    }

    // MARK: - Chrome

    private var overlayChrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if let flash = session.flash {
                Text(flash)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.paper2, in: Capsule())
                    .overlay(Capsule().stroke(Theme.gray3))
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
            if session.phase == .question || session.phase == .answer || (session.phase == .loading && !session.html.isEmpty) {
                bottomBar
            }
        }
        .animation(.easeInOut(duration: 0.15), value: session.flash)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.medium)).frame(width: 36, height: 36)
            }
            Spacer()
            if session.isDrill {
                Text("周回 · 残り \(session.counts.total)")
                    .font(.footnote.monospacedDigit()).foregroundStyle(Theme.gray1)
            } else {
                HStack(spacing: 10) {
                    CountLabel(label: "新規", value: session.counts.new, emphasized: false)
                    CountLabel(label: "学習", value: session.counts.learning, emphasized: false)
                    CountLabel(label: "復習", value: session.counts.review, emphasized: false)
                }
            }
            Spacer()
            Button { Task { await session.undo() } } label: {
                Image(systemName: "arrow.uturn.backward").font(.body).frame(width: 36, height: 36)
            }
            .disabled(!session.undoAvailable)
            toolsMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.paper.opacity(0.92))
        .foregroundStyle(Theme.ink)
    }

    private var toolsMenu: some View {
        Menu {
            Button { session.replayAudio() } label: { Label("音声をもう一度", systemImage: "speaker.wave.2") }
            Menu {
                ForEach(Array(zip(["なし", "赤", "橙", "緑", "青", "桃", "水", "紫"], 0...7)), id: \.1) { name, idx in
                    Button {
                        Task { await session.setFlag(UInt32(idx)) }
                    } label: {
                        if session.currentFlag == UInt32(idx) { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } label: { Label("フラグ", systemImage: "flag") }
            Button { Task { await session.buryCard() } } label: { Label("今日は埋める", systemImage: "tray.and.arrow.down") }
            Button { confirmSuspend = true } label: { Label("保留", systemImage: "pause.circle") }
            Button {
                Task {
                    cardStats = await session.cardStats()
                    showCardInfo = true
                }
            } label: { Label("カード情報", systemImage: "info.circle") }
            Divider()
            Button(role: .destructive) { Task { await session.forgetCard() } } label: { Label("新規に戻す", systemImage: "arrow.counterclockwise") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.body).frame(width: 36, height: 36)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if session.phase == .answer {
                HStack(spacing: 8) {
                    answerButton(.again, title: "もう一度", hint: "← スワイプ")
                    answerButton(.hard, title: "難しい", hint: nil)
                    answerButton(.good, title: "普通", hint: "↑ スワイプ")
                    answerButton(.easy, title: "簡単", hint: nil)
                }
            } else {
                Button {
                    Task { await session.showAnswer() }
                } label: {
                    Text("答えを表示")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Theme.paper)
                }
                .disabled(session.phase != .question)
                Text("カードをタップしても答えが出ます").font(.caption2).foregroundStyle(Theme.gray2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [Theme.paper.opacity(0), Theme.paper.opacity(0.95), Theme.paper], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func answerButton(_ rating: Rating, title: String, hint: String?) -> some View {
        let idx = Int(rating.rawValue)
        let label = session.current.map { $0.labels.indices.contains(idx) ? $0.labels[idx] : "" } ?? ""
        let primary = rating == .good
        return Button {
            Task { await session.answer(rating) }
        } label: {
            VStack(spacing: 3) {
                Text(label.isEmpty ? " " : label).font(.caption2.monospacedDigit()).foregroundStyle(primary ? Theme.paper.opacity(0.8) : Theme.gray1)
                Text(title).font(.subheadline.weight(primary ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(primary ? Theme.ink : Theme.paper2, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(primary ? Theme.ink : Theme.gray3))
            .foregroundStyle(primary ? Theme.paper : Theme.ink)
        }
        .disabled(session.phase != .answer)
    }

    private var finishedView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: session.isDrill ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                .font(.system(size: 44, weight: .light)).foregroundStyle(Theme.gray1)
            Text(session.isDrill ? "周回おわり" : "おつかれさまでした").font(.title3.weight(.semibold))
            Text(session.finishMessage).font(.footnote).foregroundStyle(Theme.gray1).multilineTextAlignment(.center).padding(.horizontal, 32)
            if session.answeredCount > 0 {
                Text("このセッション: \(session.answeredCount) 枚").font(.footnote.monospacedDigit()).foregroundStyle(Theme.gray2)
            }
            Spacer()
            Button { dismiss() } label: {
                Text("デッキ一覧へ").frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(Theme.paper)
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
    }
}

struct CardInfoView: View {
    let stats: Anki_Stats_CardStatsResponse?

    var body: some View {
        NavigationStack {
            List {
                if let s = stats {
                    Section("カード") {
                        row("デッキ", s.deck)
                        row("ノートタイプ", s.notetype)
                        row("カードタイプ", s.cardType)
                        row("追加日", dateString(s.added))
                        if s.hasFirstReview { row("初回学習", dateString(s.firstReview)) }
                        if s.hasLatestReview { row("最終学習", dateString(s.latestReview)) }
                        if s.hasDueDate { row("次回", dateString(s.dueDate)) }
                        row("間隔", "\(s.interval) 日")
                        if s.hasMemoryState {
                            row("安定度 (S)", String(format: "%.1f 日", s.memoryState.stability))
                            row("難易度 (D)", String(format: "%.0f%%", (s.memoryState.difficulty - 1) / 9 * 100))
                        } else {
                            row("Ease", "\(s.ease / 10)%")
                        }
                        if s.hasFsrsRetrievability { row("想起率 (R)", String(format: "%.0f%%", s.fsrsRetrievability * 100)) }
                        row("復習回数", "\(s.reviews)")
                        row("失敗回数", "\(s.lapses)")
                        row("平均時間", String(format: "%.1f 秒", s.averageSecs))
                    }
                    Section("履歴") {
                        ForEach(Array(s.revlog.enumerated()), id: \.offset) { _, e in
                            HStack {
                                Text(dateString(e.time)).font(.footnote)
                                Spacer()
                                Text(["", "もう一度", "難しい", "普通", "簡単"][Int(min(e.buttonChosen, 4))]).font(.footnote).foregroundStyle(Theme.gray1)
                                Text(intervalString(e.interval)).font(.footnote.monospacedDigit()).frame(width: 60, alignment: .trailing)
                            }
                        }
                    }
                } else {
                    Text("情報を取得できませんでした").foregroundStyle(Theme.gray1)
                }
            }
            .navigationTitle("カード情報")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(Theme.gray1); Spacer(); Text(v).multilineTextAlignment(.trailing) }.font(.footnote)
    }

    private func dateString(_ secs: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(secs))
        return d.formatted(date: .numeric, time: .omitted)
    }

    private func intervalString(_ secs: UInt32) -> String {
        if secs == 0 { return "-" }
        if secs < 3600 { return "\(secs / 60)分" }
        if secs < 86400 { return "\(secs / 3600)時間" }
        return "\(secs / 86400)日"
    }
}
