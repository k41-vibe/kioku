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
                        stat("今の章", shortName(ch.name))
                        stat("章の進み", "\(ch.introduced)/\(ch.total)")
                    }
                    stat("今日の新規", "\(status.todayNew)")
                    stat("全体", "\(status.introduced)/\(status.totalInScope)")
                    stat("期間の残り", "\(status.daysLeftInPeriod)日")
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
                        Text("今の章を周回").font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 10)
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

    @State private var unit: StudyPlan.Unit = .chapters
    @State private var amountText: String = "1"
    @State private var periodChoice: Int = 7
    @State private var customDays: Int = 14
    @State private var startDate: Date = Date()
    @State private var startChapter: Int = 0
    @State private var loaded = false

    private var chapterList: [PlanChapter] {
        model.node(for: deckID).map { PlanEngine.chapters(from: $0) } ?? []
    }

    private var periodDays: Int { periodChoice == 0 ? customDays : periodChoice }
    private var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var valid: Bool { amount > 0 && periodDays > 0 && (unit == .words || hasChapters) }

    var body: some View {
        NavigationStack {
            Form {
                Section("単位") {
                    Picker("単位", selection: $unit) {
                        Text("章").tag(StudyPlan.Unit.chapters)
                        Text("単語数").tag(StudyPlan.Unit.words)
                    }
                    .pickerStyle(.segmented)
                    if unit == .chapters && !hasChapters {
                        Text("このデッキには章(サブデッキ)がありません。先にデッキ画面の「章に分ける」で分けてください。")
                            .font(.caption).foregroundStyle(Theme.gray1)
                    }
                }
                Section("ペース") {
                    HStack {
                        TextField(unit == .chapters ? "章の数(小数可)" : "単語数", text: $amountText)
                            .keyboardType(.decimalPad)
                        Text(unit == .chapters ? "章" : "語").foregroundStyle(Theme.gray1)
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
                        Picker("開始する章", selection: $startChapter) {
                            ForEach(Array(chapterList.enumerated()), id: \.offset) { i, ch in
                                Text("\(shortName(ch.name))  (\(ch.introduced)/\(ch.total))").tag(i)
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

    private var preview: String {
        guard valid else { return "" }
        let node = model.node(for: deckID)
        let all = chapterList
        let scope = all.isEmpty ? [] : Array(all[min(startChapter, all.count - 1)...])
        let total = all.isEmpty ? Int(node?.totalIncludingChildren ?? 0) : scope.reduce(0) { $0 + $1.total }
        switch unit {
        case .chapters:
            let avg = scope.isEmpty ? 0 : total / scope.count
            let perDay = Double(avg) * amount / Double(periodDays)
            let weeks = amount > 0 ? Double(scope.count) / amount * Double(periodDays) / 7 : 0
            return String(format: "%d 章 × 平均 %d 枚。1日あたり約 %.0f 枚、全部で約 %.0f 週間。", scope.count, avg, perDay.rounded(.up), weeks)
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
            startChapter = p.startChapterIndex
        } else if !hasChapters {
            unit = .words
            amountText = "20"
            periodChoice = 1
        }
    }

    private func save() async {
        let offset = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: startDate)).day ?? 0
        let plan = StudyPlan(deckID: deckID, unit: unit, amountPerPeriod: amount, periodDays: periodDays,
                             startDay: model.today + offset, startChapterIndex: hasChapters ? startChapter : 0, previousNewLimit: nil)
        await model.setPlan(plan)
        dismiss()
    }
}
