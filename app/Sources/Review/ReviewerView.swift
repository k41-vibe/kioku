import SwiftUI

/// Reel-style study screen: a vertical pager. Page 0 = question, page 1 =
/// answer, page 2 = the next card's question (pre-rendered). Paging past the
/// answer commits the pending rating (Good by default) and the next card
/// becomes page 0 without any visible jump.
struct ReviewerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var model
    @State var session: ReviewSession
    @State private var page: Int? = 1
    @State private var pendingRating: Rating = .good
    @State private var showCardInfo = false
    @State private var cardStats: Anki_Stats_CardStatsResponse?
    @State private var confirmSuspend = false
    @State private var lastGeneration = 0
    @State private var showMemoEditor = false
    @State private var memoDraft = ""
    /// Native layout: how far the answer panel is pulled up (0...1).
    @State private var reveal: CGFloat = 0
    @State private var dragging = false

    private enum PageID: Int { case previous = 0, question = 1, answer = 2, next = 3 }

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            content
            overlayChrome
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            session.night = colorScheme == .dark
            await session.start()
        }
        .onChange(of: colorScheme) { _, new in session.night = new == .dark }
        .onChange(of: session.generation) { _, _ in
            // A new card became current: snap back to its question page without animation.
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { page = PageID.question.rawValue; reveal = 0 }
            pendingRating = .good
        }
        .onChange(of: page) { _, new in
            guard let new, session.phase == .studying else { return }
            switch PageID(rawValue: new) {
            case .previous:
                Task { await session.undo() }
            case .answer:
                if !session.isNative { Task { await session.revealAnswer() } }
            case .next:
                let rating = pendingRating
                Task { await session.answer(rating) }
            default:
                break
            }
        }
        .onDisappear {
            Task {
                await session.end()
                await model.refreshDecks()
            }
        }
        .sheet(isPresented: $showCardInfo) {
            CardInfoView(stats: cardStats)
        }
        .sheet(isPresented: $showMemoEditor) {
            MemoEditorView(text: $memoDraft) { Task { await session.saveMemo(memoDraft) } }
                .presentationDetents([.medium])
        }
        .alert("エラー", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
        .confirmationDialog("このカードを保留しますか?", isPresented: $confirmSuspend, titleVisibility: .visible) {
            Button("保留する", role: .destructive) { Task { await session.suspendCard() } }
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .finished:
            finishedView
        case .error(let msg):
            VStack(spacing: 12) {
                Text("問題が起きました").font(.headline)
                Text(msg).font(.footnote).foregroundStyle(Theme.gray1).multilineTextAlignment(.center).padding()
                Button("戻る") { dismiss() }.buttonStyle(.bordered)
            }
        case .studying:
            if let cur = session.current {
                reel(cur)
            }
        }
    }

    private func reel(_ cur: ReviewSession.Current) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            let native = session.isNative
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if let prev = session.previous {
                        anyPage(prev, height: h, interactive: false, progress: 0)
                            .overlay(alignment: .bottom) {
                                Text("下に引くと戻ります(回答を取り消し)").font(.caption2).foregroundStyle(Theme.gray2).padding(.bottom, 110)
                            }
                            .id(PageID.previous.rawValue)
                    }
                    if native, let n = cur.native {
                        NativeCardPage(card: n, memo: cur.memo, height: h, progress: reveal, interactive: true) { tags in
                            session.audio.play(tags)
                        }
                        .id("n\(cur.queued.card.id)")
                        .gesture(revealGesture(height: h))
                        .onTapGesture { openAnswer() }
                        .id(PageID.question.rawValue)
                    } else {
                        cardPage(html: cur.questionHTML, key: "q\(cur.queued.card.id)", height: h, isQuestion: true)
                            .id(PageID.question.rawValue)
                        cardPage(html: cur.answerHTML, key: "a\(cur.queued.card.id)", height: h, isQuestion: false)
                            .id(PageID.answer.rawValue)
                    }
                    Group {
                        if let nxt = session.next {
                            anyPage(nxt, height: h, interactive: false, progress: 0)
                        } else {
                            endPage(height: h)
                        }
                    }
                    .id(PageID.next.rawValue)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(native && !session.answerRevealed)
            .ignoresSafeArea(edges: .bottom)
        }
    }

    /// A page for any card (native layout when possible, template HTML otherwise).
    @ViewBuilder
    private func anyPage(_ c: ReviewSession.Current, height: CGFloat, interactive: Bool, progress: CGFloat) -> some View {
        if session.useNativeLayout, let n = c.native {
            NativeCardPage(card: n, memo: c.memo, height: height, progress: progress, interactive: interactive)
                .id("n\(c.queued.card.id)")
        } else {
            cardPage(html: c.questionHTML, key: "q\(c.queued.card.id)", height: height, isQuestion: true, interactive: interactive)
        }
    }

    /// Pull-up gesture that drags the answer panel with the finger.
    private func revealGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { v in
                guard !session.answerRevealed else { return }
                let dy = v.translation.height
                let dx = v.translation.width
                if abs(dx) > abs(dy) { return }
                dragging = true
                reveal = min(max(-dy / (height * 0.45), 0), 1)
            }
            .onEnded { v in
                let dy = v.translation.height
                let dx = v.translation.width
                dragging = false
                if !session.answerRevealed && abs(dx) > 70 && abs(dx) > abs(dy) * 1.5 {
                    if dx < 0 { commit(.again) }
                    withAnimation(.easeOut(duration: 0.2)) { reveal = 0 }
                    return
                }
                guard !session.answerRevealed else { return }
                if reveal > 0.3 || v.predictedEndTranslation.height < -160 {
                    openAnswer()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { reveal = 0 }
                }
            }
    }

    private func openAnswer() {
        guard session.phase == .studying, !session.answerRevealed else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { reveal = 1 }
        Task { await session.revealAnswer() }
    }

    private func cardPage(html: String, key: String, height: CGFloat, isQuestion: Bool, interactive: Bool = true) -> some View {
        CardWebView(html: html, mediaFolder: session.client.paths.media, controller: interactive && isQuestion ? session.web : CardWebController()) { event in
            guard interactive else { return }
            handle(event, isQuestion: isQuestion)
        }
        .id(key)
        .frame(height: height)
        .clipped()
    }

    private func endPage(height: CGFloat) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.gray1)
            Text("これが最後のカードです").font(.footnote).foregroundStyle(Theme.gray1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    private func handle(_ event: CardWebEvent, isQuestion: Bool) {
        switch event {
        case .tap(let typed), .showAnswer(let typed):
            if isQuestion, page == PageID.question.rawValue {
                Task {
                    await session.revealAnswer(typed: typed)
                    withAnimation(.easeInOut(duration: 0.3)) { page = PageID.answer.rawValue }
                }
            }
        case .play(let side, let idx):
            session.play(side: side, index: idx)
        case .swipe(let dir):
            if dir == .left { commit(.again) }
        case .loaded:
            break
        }
    }

    /// Animate to the next card, committing `rating` when the page settles.
    private func commit(_ rating: Rating) {
        guard session.phase == .studying else { return }
        pendingRating = rating
        if page == PageID.next.rawValue {
            Task { await session.answer(rating) }
        } else if session.isNative && !session.answerRevealed {
            // Rating without opening the answer (e.g. left swipe = again): open, then move on.
            Task {
                await session.revealAnswer()
                withAnimation(.easeInOut(duration: 0.3)) { page = PageID.next.rawValue }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { page = PageID.next.rawValue }
        }
    }

    // MARK: - Chrome

    private var overlayChrome: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                if let notice = session.audioNotice {
                    Text(notice)
                        .font(.caption2).foregroundStyle(Theme.gray1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.paper2)
                        .onTapGesture { session.audioNotice = nil }
                }
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
                if session.phase == .studying {
                    bottomCenter
                }
            }
            if session.phase == .studying {
                HStack {
                    Spacer()
                    rightRail
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: session.flash)
        .animation(.easeInOut(duration: 0.2), value: page)
    }

    /// Reels-style column on the right edge: rating buttons (answer side) or
    /// the "answer" button (question side). Bottom-aligned for the thumb.
    private var rightRail: some View {
        VStack(spacing: 12) {
            Spacer()
            if page == PageID.answer.rawValue || (session.isNative && session.answerRevealed && page == PageID.question.rawValue) {
                railButton(.easy, title: "簡単", symbol: "sparkles")
                railButton(.good, title: "普通", symbol: "checkmark")
                railButton(.hard, title: "難しい", symbol: "tortoise")
                railButton(.again, title: "もう一度", symbol: "arrow.counterclockwise")
                Button {
                    memoDraft = session.current?.memo ?? ""
                    showMemoEditor = true
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: (session.current?.memo.isEmpty ?? true) ? "square.and.pencil" : "note.text").font(.title3)
                            .frame(width: 52, height: 52)
                            .background(Theme.paper.opacity(0.92), in: Circle())
                            .overlay(Circle().stroke(Theme.gray3))
                            .foregroundStyle(Theme.ink)
                        Text("メモ").font(.caption2).foregroundStyle(Theme.gray1)
                    }
                }
            } else if page == PageID.question.rawValue {
                Button {
                    if session.isNative {
                        openAnswer()
                    } else {
                        Task {
                            await session.revealAnswer()
                            withAnimation(.easeInOut(duration: 0.3)) { page = PageID.answer.rawValue }
                        }
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "eye").font(.title2)
                            .frame(width: 68, height: 68)
                            .background(Theme.ink, in: Circle())
                            .foregroundStyle(Theme.paper)
                        Text("答え").font(.footnote.weight(.medium)).foregroundStyle(Theme.ink)
                    }
                }
            }
            Spacer().frame(height: 84)
        }
        .padding(.trailing, 12)
    }

    private func railButton(_ rating: Rating, title: String, symbol: String) -> some View {
        let idx = Int(rating.rawValue)
        let label = session.current.map { $0.labels.indices.contains(idx) ? $0.labels[idx] : "" } ?? ""
        let primary = rating == .good
        return Button {
            commit(rating)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3.weight(.medium))
                    .frame(width: 64, height: 64)
                    .background(primary ? Theme.ink : Theme.paper.opacity(0.94), in: Circle())
                    .overlay(Circle().stroke(primary ? Theme.ink : Theme.gray2, lineWidth: 1.2))
                    .foregroundStyle(primary ? Theme.paper : Theme.ink)
                Text(title).font(.footnote.weight(.medium)).foregroundStyle(Theme.ink)
                Text(label.isEmpty ? " " : label).font(.caption.monospacedDigit()).foregroundStyle(Theme.gray1)
            }
        }
    }

    /// Replay button, bottom centre.
    private var bottomCenter: some View {
        VStack(spacing: 8) {
            if !session.isNative, page == PageID.answer.rawValue, let memo = session.current?.memo, !memo.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "note.text").font(.caption).foregroundStyle(Theme.gray1).padding(.top, 2)
                    Text(memo).font(.footnote).foregroundStyle(Theme.ink).lineLimit(4)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Theme.paper2, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.gray3))
                .padding(.leading, 12)
                .padding(.trailing, 104)
                .onTapGesture { memoDraft = memo; showMemoEditor = true }
            }
            HStack {
                Spacer()
                Button {
                    if hasAudio { session.replayAudio() } else { session.audioNotice = "このカードに音声はありません([sound:] タグが見つかりません)" }
                } label: {
                    Image(systemName: "speaker.wave.2").font(.title3)
                        .frame(width: 48, height: 48)
                        .background(Theme.paper.opacity(0.92), in: Circle())
                        .overlay(Circle().stroke(Theme.gray2))
                        .foregroundStyle(Theme.ink)
                }
                .opacity(hasAudio ? 1 : 0.45)
                Spacer()
            }
        }
        .padding(.bottom, 14)
    }

    private var hasAudio: Bool {
        guard let cur = session.current else { return false }
        if session.isNative, let n = cur.native {
            return session.answerRevealed ? !(n.answerAudio.isEmpty && n.questionAudio.isEmpty) : !n.questionAudio.isEmpty
        }
        return page == PageID.answer.rawValue ? !cur.answer.avTags.isEmpty : !cur.question.avTags.isEmpty
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
            Button(role: .destructive) { Task { await session.forgetCard() } } label: { Label("このカードを新規に戻す", systemImage: "arrow.counterclockwise") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.body).frame(width: 36, height: 36)
        }
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


struct MemoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let onSave: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .focused($focused)
                    .font(.body)
                    .padding(8)
                    .background(Theme.paper2, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.gray3))
                Text("ノートの「メモ」フィールドに保存されます(書き出しても残ります)。").font(.caption2).foregroundStyle(Theme.gray2)
            }
            .padding(16)
            .background(Theme.paper)
            .navigationTitle("メモ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(); dismiss() } }
            }
            .onAppear { focused = true }
        }
    }
}
