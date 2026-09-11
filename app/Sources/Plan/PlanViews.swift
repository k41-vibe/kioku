import SwiftUI

/// Card shown at the top of the deck list for each deck with a plan.
struct PlanCardView: View {
    @Environment(AppModel.self) private var model
    let status: PlanStatus
    let onStudy: () -> Void
    let onDrill: (PlanChapter) -> Void

    private var deckName: String { model.deckName(status.plan.deckID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(shortName(deckName)).font(.headline)
                Spacer()
                Text(status.plan.label).font(.caption).foregroundStyle(Theme.gray1)
            }
            if status.finished {
                Text("全部導入済み。あとは復習だけです。").font(.footnote).foregroundStyle(Theme.gray1)
            } else {
                HStack(spacing: 14) {
                    if let ch = status.currentChapter {
                        stat("今の\(status.plan.unitName)", status.plan.level >= 2 ? sectionLabel(ch.name) : shortName(ch.name))
                        stat("\(status.plan.unitName)の進み", "\(ch.introduced)/\(ch.total)")
                    }
                    stat("今日の新規", "\(status.todayNew)")
                    stat("全体", "\(status.introduced)/\(status.totalInScope)")
                    stat(status.plan.isDeadline ? "期限まで" : "期間の残り", "\(status.daysLeftInPeriod)日")
                }
                ProgressView(value: Double(status.introduced), total: Double(max(status.totalInScope, 1)))
                    .tint(Theme.ink)
            }
            HStack(spacing: 8) {
                Button(action: onStudy) {
                    Text("学習する").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(Theme.paper)
                }
                .buttonStyle(.plain)
                if let ch = status.currentChapter {
                    Button { onDrill(ch) } label: {
                        Text("今の\(status.plan.unitName)を周回").font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Theme.paper2, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.gray3)).foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(Theme.paper2, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.gray3))
    }

    /// "Deck::01::3" -> "01·3"
    private func sectionLabel(_ full: String) -> String {
        let parts = full.components(separatedBy: "::")
        return parts.suffix(2).joined(separator: "·")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(Theme.gray1)
            Text(value).font(.footnote.monospacedDigit().weight(.medium)).lineLimit(1)
        }
    }
}

/// Create or edit the pacing plan for a deck.
struct PlanSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let deckID: Int64
    let deckName: String
    let hasChapters: Bool
    let hasSections: Bool

    @State private var level: Int = 1
    @State private var unit: StudyPlan.Unit = .chapters
    @State private var amountText: String = "1"
    @State private var periodChoice: Int = 7
    @State private var customDays: Int = 14
    @State private var startDate: Date = Date()
    @State private var startChapter: Int = 0
    @State private var mode: Int = 0            // 0 = pace, 1 = deadline
    @State private var endChapter: Int = 0
    @State private var endDate: Date = Calendar.current.date(byAdding: .day, value: 4, to: Date()) ?? Date()
    @State private var loaded = false

    private var chapterList: [PlanChapter] {
        model.node(for: deckID).map { PlanEngine.chapters(from: $0, level: level) } ?? []
    }
    private var unitName: String { level >= 2 ? "節" : "章" }

    private var periodDays: Int { periodChoice == 0 ? customDays : periodChoice }
    private var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var valid: Bool {
        if mode == 1 { return hasChapters && endChapter >= startChapter }
        return amount > 0 && periodDays > 0 && (unit == .words || hasChapters)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("決め方") {
                    Picker("決め方", selection: $mode) {
                        Text("ペース(1章/週 など)").tag(0)
                        Text("期限(いつまでに)").tag(1)
                    }
                    .pickerStyle(.segmented)
                    if mode == 1 && !hasChapters {
                        Text("期限型は章(サブデッキ)単位で範囲を選びます。先に「章に分ける」で分けてください。")
                            .font(.caption).foregroundStyle(Theme.gray1)
                    }
                }
                if mode == 0 {
                Section("単位") {
                    Picker("単位", selection: $unit) {
                        Text(unitName).tag(StudyPlan.Unit.chapters)
                        Text("単語数").tag(StudyPlan.Unit.words)
                    }
                    .pickerStyle(.segmented)
                    if hasSections {
                        Picker("数える階層", selection: $level) {
                            Text("章(デッキ直下)").tag(1)
                            Text("節(章の下)").tag(2)
                        }
                        .onChange(of: level) { _, _ in startChapter = 0 }
                    }
                    if unit == .chapters && !hasChapters {
                        Text("このデッキには章(サブデッキ)がありません。先にデッキ画面の「章に分ける」で分けてください。")
                            .font(.caption).foregroundStyle(Theme.gray1)
                    }
                }
                }
                Section(mode == 1 ? "範囲と期限" : "ペース") {
                    if mode == 1 {
                        if hasSections {
                            Picker("数える階層", selection: $level) {
                                Text("章(デッキ直下)").tag(1)
                                Text("節(章の下)").tag(2)
                            }
                            .onChange(of: level) { _, _ in startChapter = 0; endChapter = 0 }
                        }
                        Picker("\(unitName) ここから", selection: $startChapter) {
                            ForEach(Array(chapterList.enumerated()), id: \.offset) { i, ch in
                                Text("\(unitLabel(ch))  (\(ch.introduced)/\(ch.total))").tag(i)
                            }
                        }
                        .onChange(of: startChapter) { _, v in if endChapter < v { endChapter = v } }
                        Picker("\(unitName) ここまで", selection: $endChapter) {
                            ForEach(Array(chapterList.enumerated()), id: \.offset) { i, ch in
                                if i >= startChapter { Text("\(unitLabel(ch))  (\(ch.introduced)/\(ch.total))").tag(i) }
                            }
                        }
                        DatePicker("この日までに終える", selection: $endDate, in: Date()..., displayedComponents: .date)
                    }
                    if mode == 0 {
                    HStack {
                        TextField(unit == .chapters ? "\(unitName)の数(小数可)" : "単語数", text: $amountText)
                            .keyboardType(.decimalPad)
                        Text(unit == .chapters ? unitName : "語").foregroundStyle(Theme.gray1)
                        Text("/").foregroundStyle(Theme.gray2)
                        Picker("", selection: $periodChoice) {
                            Text("日").tag(1)
                            Text("週").tag(7)
                            Text("任意").tag(0)
                        }
                        .labelsHidden()
                    }
                    if periodChoice == 0 {
                        Stepper("\(customDays) 日ごと", value: $customDays, in: 2...90)
                    }
                    DatePicker("開始日", selection: $startDate, displayedComponents: .date)
                    if hasChapters {
                        Picker("開始する\(unitName)", selection: $startChapter) {
                            ForEach(Array(chapterList.enumerated()), id: \.offset) { i, ch in
                                Text("\(unitLabel(ch))  (\(ch.introduced)/\(ch.total))").tag(i)
                            }
                        }
                    }
                    }
                }
                Section {
                    Text(preview).font(.footnote).foregroundStyle(Theme.gray1)
                }
                if model.plan(for: deckID) != nil {
                    Section {
                        Button("ペースをやめる(上限を元に戻す)", role: .destructive) {
                            Task { await model.removePlan(deckID: deckID); dismiss() }
                        }
                    }
                }
            }
            .navigationTitle("ペースを決める")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }.disabled(!valid)
                }
            }
            .onAppear(perform: loadExisting)
        }
    }

    private func unitLabel(_ ch: PlanChapter) -> String {
        level >= 2 ? ch.name.components(separatedBy: "::").suffix(2).joined(separator: "·") : shortName(ch.name)
    }

    private var preview: String {
        guard valid else { return "" }
        let node = model.node(for: deckID)
        let all = chapterList
        if mode == 1 {
            guard !all.isEmpty else { return "" }
            let lo = min(startChapter, all.count - 1), hi = min(max(endChapter, lo), all.count - 1)
            let scope = all[lo...hi]
            let remaining = scope.reduce(0) { $0 + $1.newRemaining }
            let days = max((Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: endDate)).day ?? 0) + 1, 1)
            return String(format: "残り %d 枚を %d 日で。今日から 1日あたり約 %.0f 枚(遅れた分は翌日以降に上乗せ)。", remaining, days, (Double(remaining) / Double(days)).rounded(.up))
        }
        let scope = all.isEmpty ? [] : Array(all[min(startChapter, all.count - 1)...])
        let total = all.isEmpty ? Int(node?.totalIncludingChildren ?? 0) : scope.reduce(0) { $0 + $1.total }
        switch unit {
        case .chapters:
            let avg = scope.isEmpty ? 0 : total / scope.count
            let perDay = Double(avg) * amount / Double(periodDays)
            let weeks = amount > 0 ? Double(scope.count) / amount * Double(periodDays) / 7 : 0
            return String(format: "%d \(unitName) × 平均 %d 枚。1日あたり約 %.0f 枚、全部で約 %.0f 週間。", scope.count, avg, perDay.rounded(.up), weeks)
        case .words:
            let perDay = amount / Double(periodDays)
            let days = perDay > 0 ? Double(total) / perDay : 0
            return String(format: "対象 %d 枚。1日あたり約 %.0f 枚、全部で約 %.0f 日(%.0f 週間)。", total, perDay.rounded(.up), days, days / 7)
        }
    }

    private func loadExisting() {
        guard !loaded else { return }
        loaded = true
        if let p = model.plan(for: deckID) {
            unit = p.unit
            amountText = p.amountPerPeriod == p.amountPerPeriod.rounded() ? String(Int(p.amountPerPeriod)) : String(p.amountPerPeriod)
            periodChoice = [1, 7].contains(p.periodDays) ? p.periodDays : 0
            customDays = p.periodDays
            startDate = Calendar.current.date(byAdding: .day, value: p.startDay - model.today, to: Date()) ?? Date()
            level = p.level
            startChapter = p.startChapterIndex
            if let e = p.endDay {
                mode = 1
                endChapter = p.endChapterIndex ?? p.startChapterIndex
                endDate = Calendar.current.date(byAdding: .day, value: e - model.today, to: Date()) ?? Date()
            }
        } else if !hasChapters {
            unit = .words
            amountText = "20"
            periodChoice = 1
        }
    }

    private func save() async {
        let offset = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: startDate)).day ?? 0
        var plan = StudyPlan(deckID: deckID, unit: unit, amountPerPeriod: amount, periodDays: periodDays,
                             startDay: model.today + offset, startChapterIndex: hasChapters ? startChapter : 0, level: level, previousNewLimit: nil)
        if mode == 1 {
            let endOffset = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: endDate)).day ?? 0
            plan.unit = .chapters
            plan.startDay = model.today
            plan.endDay = model.today + max(endOffset, 0)
            plan.endChapterIndex = max(endChapter, startChapter)
        }
        await model.setPlan(plan)
        dismiss()
    }
}
