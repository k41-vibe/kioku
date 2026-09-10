import SwiftUI
import Charts

struct IntPoint: Identifiable { let x: Int; let y: Int; var id: Int { x } }
struct LabelPoint: Identifiable { let label: String; let y: Int; var id: String { label } }

/// Statistics from rslib's Graphs RPC, drawn with Swift Charts in monochrome.
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let search: String
    @State private var graphs: Anki_Stats_GraphsResponse?
    @State private var error: String?
    @State private var days: UInt32 = 31

    var body: some View {
        NavigationStack {
            ScrollView {
                if let g = graphs {
                    VStack(alignment: .leading, spacing: 28) {
                        todaySection(g.today)
                        futureDue(g.futureDue)
                        reviewCounts(g.reviews)
                        cardCounts(g.cardCounts)
                        trueRetention(g.trueRetention)
                        intervals(g.intervals, title: g.fsrs ? "安定度の分布(日)" : "復習間隔の分布(日)", data: g.fsrs ? g.stability : g.intervals)
                        if g.fsrs {
                            histogram(title: "難易度の分布", map: g.difficulty.eases, average: g.difficulty.average, suffix: "%")
                        } else {
                            histogram(title: "Ease の分布", map: g.eases.eases, average: g.eases.average, suffix: "%")
                        }
                        buttons(g.buttons)
                        hours(g.hours)
                    }
                    .padding(16)
                } else if let error {
                    Text(error).foregroundStyle(Theme.gray1).padding()
                } else {
                    ProgressView().padding(40)
                }
            }
            .background(Theme.paper)
            .navigationTitle(search.isEmpty ? "統計" : "統計 · \(shortName(search.replacingOccurrences(of: "deck:", with: "").replacingOccurrences(of: "\"", with: "")))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Picker("期間", selection: $days) {
                        Text("1か月").tag(UInt32(31))
                        Text("3か月").tag(UInt32(90))
                        Text("1年").tag(UInt32(365))
                        Text("全部").tag(UInt32(0))
                    }
                    .pickerStyle(.menu)
                }
            }
            .task(id: days) { await load() }
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        let s = search
        let d = days
        do {
            graphs = try await client.perform { c in try c.graphs(search: s, days: d) }
        } catch {
            self.error = "\(error)"
        }
    }

    // MARK: sections

    private func header(_ t: String, _ sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.headline)
            if let sub { Text(sub).font(.caption).foregroundStyle(Theme.gray1) }
        }
    }

    private func todaySection(_ t: Anki_Stats_GraphsResponse.Today) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header("今日")
            if t.answerCount == 0 {
                Text("まだ学習していません").font(.footnote).foregroundStyle(Theme.gray1)
            } else {
                let mins = Double(t.answerMillis) / 60000
                let rate = t.answerCount > 0 ? Double(t.correctCount) / Double(t.answerCount) * 100 : 0
                HStack(spacing: 0) {
                    tile("\(t.answerCount)", "枚")
                    tile(String(format: "%.0f", mins), "分")
                    tile(String(format: "%.0f%%", rate), "正答")
                    tile("\(t.learnCount)/\(t.reviewCount)/\(t.relearnCount)", "学/復/再")
                }
                if t.matureCount > 0 {
                    Text("成熟カード: \(t.matureCorrect)/\(t.matureCount) 正解").font(.caption).foregroundStyle(Theme.gray1)
                }
            }
        }
    }

    private func tile(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title3.monospacedDigit().weight(.semibold))
            Text(l).font(.caption2).foregroundStyle(Theme.gray1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.paper2, in: RoundedRectangle(cornerRadius: 10))
    }

    private func futureDue(_ f: Anki_Stats_GraphsResponse.FutureDue) -> some View {
        let horizon = min(Int(days == 0 ? 365 : days), 365)
        let points = (0...horizon).map { d in IntPoint(x: d, y: Int(f.futureDue[Int32(d)] ?? 0)) }
        let total = points.reduce(0) { $0 + $1.y }
        return VStack(alignment: .leading, spacing: 8) {
            header("これから期限が来るカード", "今後 \(horizon) 日で \(total) 枚" + (f.haveBacklog ? "・期限切れあり" : ""))
            Chart(points) { p in
                BarMark(x: .value("日", p.x), y: .value("枚", p.y))
                    .foregroundStyle(Theme.ink)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
            .frame(height: 140)
        }
    }

    private func reviewCounts(_ r: Anki_Stats_GraphsResponse.ReviewCountsAndTimes) -> some View {
        let horizon = Int(days == 0 ? 365 : days)
        struct Row: Identifiable { let id: Int; let kind: String; let count: Int }
        var rows: [Row] = []
        for d in stride(from: -horizon, through: 0, by: 1) {
            let v = r.count[Int32(d)]
            let learn = Int((v?.learn ?? 0) + (v?.relearn ?? 0))
            let young = Int(v?.young ?? 0)
            let mature = Int(v?.mature ?? 0)
            rows.append(Row(id: d * 3, kind: "学習", count: learn))
            rows.append(Row(id: d * 3 + 1, kind: "若い", count: young))
            rows.append(Row(id: d * 3 + 2, kind: "成熟", count: mature))
        }
        let total = rows.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 8) {
            header("学習した枚数", "過去 \(horizon) 日で \(total) 枚")
            Chart(rows) { row in
                BarMark(x: .value("日", row.id / 3), y: .value("枚", row.count))
                    .foregroundStyle(by: .value("種類", row.kind))
            }
            .chartForegroundStyleScale(["学習": Theme.gray2, "若い": Theme.gray1, "成熟": Theme.ink])
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
            .frame(height: 140)
        }
    }

    private func cardCounts(_ c: Anki_Stats_GraphsResponse.CardCounts) -> some View {
        let x = c.excludingInactive
        let items: [(String, UInt32, Color)] = [
            ("未学習", x.newCards, Theme.gray3), ("学習中", x.learn + x.relearn, Theme.gray2),
            ("若い", x.young, Theme.gray1), ("成熟", x.mature, Theme.ink),
            ("保留", x.suspended, Theme.paper2), ("埋め", x.buried, Theme.paper2),
        ]
        let total = items.reduce(0) { $0 + $1.1 }
        return VStack(alignment: .leading, spacing: 8) {
            header("カードの内訳", "全 \(total) 枚")
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(items.indices, id: \.self) { i in
                        if items[i].1 > 0 {
                            Rectangle().fill(items[i].2)
                                .frame(width: max(2, geo.size.width * CGFloat(items[i].1) / CGFloat(max(total, 1))))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.gray3))
            }
            .frame(height: 16)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(items[i].2).frame(width: 10, height: 10).overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.gray3))
                        Text("\(items[i].0) \(items[i].1)").font(.caption.monospacedDigit())
                    }
                }
            }
        }
    }

    private func trueRetention(_ t: Anki_Stats_GraphsResponse.TrueRetentionStats) -> some View {
        func pct(_ r: Anki_Stats_GraphsResponse.TrueRetentionStats.TrueRetention) -> (String, String, String) {
            func p(_ pass: UInt32, _ fail: UInt32) -> String {
                let n = pass + fail
                return n == 0 ? "-" : String(format: "%.0f%%", Double(pass) / Double(n) * 100)
            }
            return (p(r.youngPassed, r.youngFailed), p(r.maturePassed, r.matureFailed),
                    p(r.youngPassed + r.maturePassed, r.youngFailed + r.matureFailed))
        }
        let rows: [(String, Anki_Stats_GraphsResponse.TrueRetentionStats.TrueRetention)] = [
            ("今日", t.today), ("昨日", t.yesterday), ("1週間", t.week), ("1か月", t.month), ("1年", t.year), ("全期間", t.allTime),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            header("実際の定着率", "復習で「もう一度」以外を押せた割合")
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("若い").font(.caption).foregroundStyle(Theme.gray1)
                    Text("成熟").font(.caption).foregroundStyle(Theme.gray1)
                    Text("合計").font(.caption).foregroundStyle(Theme.gray1)
                }
                ForEach(rows.indices, id: \.self) { i in
                    let v = pct(rows[i].1)
                    GridRow {
                        Text(rows[i].0).font(.footnote).gridColumnAlignment(.leading)
                        Text(v.0).font(.footnote.monospacedDigit())
                        Text(v.1).font(.footnote.monospacedDigit())
                        Text(v.2).font(.footnote.monospacedDigit().weight(.semibold))
                    }
                }
            }
        }
    }

    private func intervals(_ base: Anki_Stats_GraphsResponse.Intervals, title: String, data: Anki_Stats_GraphsResponse.Intervals) -> some View {
        let buckets: [(String, ClosedRange<UInt32>)] = [("1日", 0...1), ("2-7", 2...7), ("8-30", 8...30), ("31-90", 31...90), ("91-365", 91...365), ("1年+", 366...UInt32.max)]
        let points = buckets.map { b in LabelPoint(label: b.0, y: data.intervals.filter { b.1.contains($0.key) }.reduce(0) { $0 + Int($1.value) }) }
        return VStack(alignment: .leading, spacing: 8) {
            header(title)
            Chart(points) { p in
                BarMark(x: .value("範囲", p.label), y: .value("枚", p.y)).foregroundStyle(Theme.ink)
            }
            .frame(height: 130)
        }
    }

    private func histogram(title: String, map: [UInt32: UInt32], average: Float, suffix: String) -> some View {
        let points = map.keys.sorted().map { k in IntPoint(x: Int(k), y: Int(map[k] ?? 0)) }
        return VStack(alignment: .leading, spacing: 8) {
            header(title, String(format: "平均 %.0f%@", average, suffix))
            Chart(points) { p in
                BarMark(x: .value("値", p.x), y: .value("枚", p.y)).foregroundStyle(Theme.ink)
            }
            .frame(height: 120)
        }
    }

    private func buttons(_ b: Anki_Stats_GraphsResponse.Buttons) -> some View {
        let c = days == 0 ? b.allTime : (days <= 31 ? b.oneMonth : (days <= 90 ? b.threeMonths : b.oneYear))
        func sum(_ arr: [UInt32]) -> [Int] { (0..<4).map { i in i < arr.count ? Int(arr[i]) : 0 } }
        let learning = sum(c.learning), young = sum(c.young), mature = sum(c.mature)
        let names = ["もう一度", "難しい", "普通", "簡単"]
        struct Row: Identifiable { let id: String; let group: String; let count: Int }
        var rows: [Row] = []
        for i in 0..<4 {
            rows.append(Row(id: "l\(i)", group: names[i], count: learning[i]))
            rows.append(Row(id: "y\(i)", group: names[i], count: young[i]))
            rows.append(Row(id: "m\(i)", group: names[i], count: mature[i]))
        }
        let total = rows.reduce(0) { $0 + $1.count }
        let again = learning[0] + young[0] + mature[0]
        return VStack(alignment: .leading, spacing: 8) {
            header("押したボタン", total > 0 ? String(format: "正答率 %.0f%%", Double(total - again) / Double(total) * 100) : nil)
            Chart(rows) { r in
                BarMark(x: .value("ボタン", r.group), y: .value("回", r.count))
                    .foregroundStyle(by: .value("種類", r.id.hasPrefix("l") ? "学習" : (r.id.hasPrefix("y") ? "若い" : "成熟")))
            }
            .chartForegroundStyleScale(["学習": Theme.gray2, "若い": Theme.gray1, "成熟": Theme.ink])
            .frame(height: 130)
        }
    }

    private func hours(_ h: Anki_Stats_GraphsResponse.Hours) -> some View {
        let arr = days == 0 ? h.allTime : (days <= 31 ? h.oneMonth : (days <= 90 ? h.threeMonths : h.oneYear))
        let points = arr.indices.map { i in IntPoint(x: i, y: Int(arr[i].total)) }
        return VStack(alignment: .leading, spacing: 8) {
            header("時間帯別の学習")
            Chart(points) { p in
                BarMark(x: .value("時", p.x), y: .value("回", p.y)).foregroundStyle(Theme.ink)
            }
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) }
            .frame(height: 110)
        }
    }
}
