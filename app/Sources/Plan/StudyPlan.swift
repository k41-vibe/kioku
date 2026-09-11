import Foundation

/// A pacing plan for one deck: "N chapters per period" or "N words per period".
/// Stored as JSON in the collection config (key `kioku.plans`) so it travels
/// with the collection and its backups.
struct StudyPlan: Codable, Identifiable, Equatable {
    enum Unit: String, Codable, Equatable {
        case chapters
        case words
    }

    var id: Int64 { deckID }
    var deckID: Int64
    var unit: Unit
    /// Chapters per period (may be fractional) or words per period.
    var amountPerPeriod: Double
    /// Length of one period in days (1 = daily, 7 = weekly).
    var periodDays: Int
    /// Day number (Anki `days_elapsed`) on which the plan starts.
    var startDay: Int
    /// Index (0-based, study order) of the first chapter in scope. Chapters
    /// before it are left alone and never introduce new cards.
    var startChapterIndex: Int = 0
    /// Which subdeck level counts as a unit: 1 = 章 (direct children), 2 = 節 (grandchildren).
    var level: Int = 1
    /// Original per-deck new limit before the plan took over (nil = preset).
    var previousNewLimit: UInt32?

    var unitName: String { level >= 2 ? "節" : "章" }

    init(deckID: Int64, unit: Unit, amountPerPeriod: Double, periodDays: Int, startDay: Int,
         startChapterIndex: Int = 0, level: Int = 1, previousNewLimit: UInt32? = nil) {
        self.deckID = deckID
        self.unit = unit
        self.amountPerPeriod = amountPerPeriod
        self.periodDays = periodDays
        self.startDay = startDay
        self.startChapterIndex = startChapterIndex
        self.level = level
        self.previousNewLimit = previousNewLimit
    }

    private enum CodingKeys: String, CodingKey {
        case deckID, unit, amountPerPeriod, periodDays, startDay, startChapterIndex, level, previousNewLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deckID = try c.decode(Int64.self, forKey: .deckID)
        unit = try c.decode(Unit.self, forKey: .unit)
        amountPerPeriod = try c.decode(Double.self, forKey: .amountPerPeriod)
        periodDays = try c.decode(Int.self, forKey: .periodDays)
        startDay = try c.decode(Int.self, forKey: .startDay)
        startChapterIndex = try c.decodeIfPresent(Int.self, forKey: .startChapterIndex) ?? 0
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 1
        previousNewLimit = try c.decodeIfPresent(UInt32.self, forKey: .previousNewLimit)
    }

    var perDay: Double { amountPerPeriod / Double(max(periodDays, 1)) }

    var label: String {
        let period: String
        switch periodDays {
        case 1: period = "日"
        case 7: period = "週"
        default: period = "\(periodDays)日"
        }
        switch unit {
        case .chapters:
            let a = amountPerPeriod == amountPerPeriod.rounded() ? String(Int(amountPerPeriod)) : String(format: "%.1f", amountPerPeriod)
            return "\(a)\(unitName)/\(period)"
        case .words:
            return "\(Int(amountPerPeriod))語/\(period)"
        }
    }
}

/// One chapter (subdeck) with card counts.
struct PlanChapter: Equatable {
    var deckID: Int64
    var name: String
    var total: Int
    var newRemaining: Int
    var introduced: Int { total - newRemaining }
}

/// What the plan wants today.
struct PlanStatus: Equatable {
    var plan: StudyPlan
    var dayIndex: Int                 // days since start (0 = first day)
    var targetIntroducedByToday: Int  // cumulative cards that should be introduced after today
    var introduced: Int               // cards already introduced (non-new) in scope
    var totalInScope: Int
    var todayNew: Int                 // new cards to introduce today
    var currentChapterIndex: Int?     // index into `chapters` (all chapters of the deck)
    var chapters: [PlanChapter]
    var chapterLimits: [Int64: UInt32] // subdeck id -> new limit to set
    var daysLeftInPeriod: Int
    var finished: Bool { introduced >= totalInScope }

    var currentChapter: PlanChapter? {
        guard let i = currentChapterIndex, i < chapters.count else { return nil }
        return chapters[i]
    }
}

enum PlanEngine {
    static let unlimited: UInt32 = 9999

    /// Pure computation, unit-testable. `chapters` must be in study order and
    /// contain every chapter of the deck (scope is applied here).
    static func status(plan: StudyPlan, today: Int, chapters: [PlanChapter], deckTotal: Int, deckNewRemaining: Int) -> PlanStatus {
        let day = max(today - plan.startDay, 0)
        let daysLeftInPeriod = max(plan.periodDays - (day % max(plan.periodDays, 1)), 1)
        let start = min(max(plan.startChapterIndex, 0), max(chapters.count - 1, 0))
        let scope = chapters.isEmpty ? [] : Array(chapters[start...])
        var limits: [Int64: UInt32] = [:]
        for ch in chapters.prefix(start) { limits[ch.deckID] = 0 }

        // Totals over the scope (whole deck when there are no chapters).
        let scopeTotal = chapters.isEmpty ? deckTotal : scope.reduce(0) { $0 + $1.total }
        let scopeIntroduced = chapters.isEmpty ? (deckTotal - deckNewRemaining) : scope.reduce(0) { $0 + $1.introduced }

        switch plan.unit {
        case .words:
            let target = min(Int((plan.perDay * Double(day + 1)).rounded(.up)), scopeTotal)
            let todayNew = max(target - scopeIntroduced, 0)
            for ch in scope { limits[ch.deckID] = unlimited }
            let current = scope.firstIndex { $0.newRemaining > 0 }.map { $0 + start }
            return PlanStatus(plan: plan, dayIndex: day, targetIntroducedByToday: target, introduced: scopeIntroduced,
                              totalInScope: scopeTotal, todayNew: todayNew, currentChapterIndex: current,
                              chapters: chapters, chapterLimits: limits, daysLeftInPeriod: daysLeftInPeriod)

        case .chapters:
            guard !scope.isEmpty else {
                return PlanStatus(plan: plan, dayIndex: day, targetIntroducedByToday: 0, introduced: scopeIntroduced,
                                  totalInScope: scopeTotal, todayNew: 0, currentChapterIndex: nil,
                                  chapters: chapters, chapterLimits: limits, daysLeftInPeriod: daysLeftInPeriod)
            }
            // Cumulative chapters (within scope) that should be introduced by the end of today.
            let f = min(plan.perDay * Double(day + 1), Double(scope.count))
            let full = Int(f.rounded(.down))
            let frac = f - Double(full)
            var target = 0
            for (i, ch) in scope.enumerated() {
                if i < full {
                    target += ch.total
                    limits[ch.deckID] = unlimited
                } else if i == full && frac > 0 {
                    let want = Int((Double(ch.total) * frac).rounded(.up))
                    target += want
                    limits[ch.deckID] = UInt32(max(want - ch.introduced, 0))
                } else {
                    limits[ch.deckID] = 0
                }
            }
            let todayNew = max(min(target, scopeTotal) - scopeIntroduced, 0)
            let currentInScope = scope.firstIndex { $0.newRemaining > 0 && (limits[$0.deckID] ?? 0) > 0 } ?? min(full, scope.count - 1)
            return PlanStatus(plan: plan, dayIndex: day, targetIntroducedByToday: min(target, scopeTotal), introduced: scopeIntroduced,
                              totalInScope: scopeTotal, todayNew: todayNew, currentChapterIndex: currentInScope + start,
                              chapters: chapters, chapterLimits: limits, daysLeftInPeriod: daysLeftInPeriod)
        }
    }

    /// Units at `level` below the deck node (1 = children, 2 = grandchildren), flattened in tree order.
    static func chapters(from node: DeckTreeNode, level: Int = 1) -> [PlanChapter] {
        let kids = node.children.filter { !$0.filtered }
        if level <= 1 {
            return kids.map { c in
                PlanChapter(deckID: c.deckID, name: c.name, total: Int(c.totalIncludingChildren), newRemaining: Int(newRemaining(in: c)))
            }
        }
        return kids.flatMap { chapters(from: $0, level: level - 1) }
    }

    /// Does the deck have subdecks at the given depth?
    static func hasLevel(_ node: DeckTreeNode, _ level: Int) -> Bool {
        !chapters(from: node, level: level).isEmpty
    }

    static func newRemaining(in node: DeckTreeNode) -> UInt32 {
        node.newUncapped + node.children.reduce(0) { $0 + newRemaining(in: $1) }
    }
}

// MARK: - Persistence + applying limits (needs the backend)

extension AnkiClient {
    private static let plansKey = "kioku.plans"

    func loadPlans() throws -> [StudyPlan] {
        guard let data = try configJSON(Self.plansKey) else { return [] }
        return (try? JSONDecoder().decode([StudyPlan].self, from: data)) ?? []
    }

    func savePlans(_ plans: [StudyPlan]) throws {
        let data = try JSONEncoder().encode(plans)
        try setConfigJSON(Self.plansKey, json: data)
    }

    /// Write today's new-card limits for a plan into the decks. Returns the status used.
    @discardableResult
    func applyPlan(_ plan: StudyPlan, tree: DeckTreeNode, today: Int) throws -> PlanStatus? {
        guard let node = Self.find(plan.deckID, in: tree) else { return nil }
        let chapters = PlanEngine.chapters(from: node, level: plan.level)
        let status = PlanEngine.status(plan: plan, today: today, chapters: chapters,
                                       deckTotal: Int(node.totalIncludingChildren), deckNewRemaining: Int(PlanEngine.newRemaining(in: node)))
        try setNewLimit(deckID: plan.deckID, limit: UInt32(status.todayNew))
        if plan.level >= 2 {
            // Intermediate chapters must not cap their sections.
            for c in node.children where !c.filtered { try setNewLimit(deckID: c.deckID, limit: PlanEngine.unlimited) }
        }
        for (did, limit) in status.chapterLimits {
            try setNewLimit(deckID: did, limit: limit)
        }
        return status
    }

    /// Restore the deck (and its chapters) to the preset's limit.
    func clearPlanLimits(_ plan: StudyPlan, tree: DeckTreeNode) throws {
        try setNewLimit(deckID: plan.deckID, limit: plan.previousNewLimit)
        if let node = Self.find(plan.deckID, in: tree) {
            for c in node.children where !c.filtered {
                try setNewLimit(deckID: c.deckID, limit: nil)
                for g in c.children where !g.filtered { try setNewLimit(deckID: g.deckID, limit: nil) }
            }
        }
    }

    func setNewLimit(deckID: Int64, limit: UInt32?) throws {
        var d = try deck(deckID)
        guard case .normal(var n)? = d.kind else { return }
        if let limit {
            if n.hasNewLimit && n.newLimit == limit { return }
            n.newLimit = limit
        } else {
            if !n.hasNewLimit { return }
            n.clearNewLimit()
        }
        d.kind = .normal(n)
        try updateDeck(d)
    }

    func currentNewLimit(deckID: Int64) throws -> UInt32? {
        let d = try deck(deckID)
        guard case .normal(let n)? = d.kind, n.hasNewLimit else { return nil }
        return n.newLimit
    }

    static func find(_ id: Int64, in node: DeckTreeNode) -> DeckTreeNode? {
        if node.deckID == id { return node }
        for c in node.children { if let hit = find(id, in: c) { return hit } }
        return nil
    }
}
