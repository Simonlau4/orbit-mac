import Foundation
import OrbitCore

struct CleanupResultsIndex: Sendable {
    let itemsByID: [String: CleanupItem]
    let itemOrder: [String: Int]
    let groupItemIDs: [String: Set<String>]
    let groups: [CleanupGroup]
    let totalBytes: Int64
    let permissionCount: Int
    let unreadCount: Int
    let limited: Bool
    let runningEntries: [CleanupRetainedSummary]
    let runningBytes: Int64
    let runningPartial: Bool
    let recentBytes: Int64
    let recentPartial: Bool
    let retained: [CleanupRetainedSummary]
    let rows: [CleanupRow]
    let recommendedIDs: Set<String>
    let runningApps: [String]

    init(_ scan: CleanupScan? = nil, appName: (String) -> String? = installedAppName) {
        let items = scan?.items ?? []
        itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        itemOrder = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        groups = scan?.groups ?? []
        groupItemIDs = Dictionary(groups.map { ($0.id, Set($0.items.map(\.id))) }, uniquingKeysWith: { first, _ in first })
        totalBytes = items.reduce(0) { $0 + $1.bytes }
        let issues = scan?.issues ?? [], entries = scan?.retained ?? []
        permissionCount = issues.filter { $0.kind == .permission }.count
        unreadCount = max(scan?.blockedCount ?? 0, issues.filter { $0.kind == .permission || $0.kind == .io }.count)
        limited = scan?.isPartial == true || issues.contains { $0.kind == .limit || $0.kind == .cancelled }
        runningEntries = entries.filter { $0.reason == .runningApplication }
        runningBytes = runningEntries.reduce(0) { $0 + $1.bytes }
        runningPartial = runningEntries.contains { $0.isPartial }
        let recent = entries.filter { $0.reason == .recent }
        recentBytes = recent.reduce(0) { $0 + $1.bytes }; recentPartial = recent.contains { $0.isPartial }
        retained = Array(entries.sorted { $0.bytes > $1.bytes }.prefix(30))
        rows = groups.map { group in
            let folder = group.items.count == 1 && group.items[0].contents != nil
            let location = folder ? group.items[0].url : commonFolder(group.items.map(\.url))
            let advice = CleanupAdvisor.advice(name: group.name, category: group.category, location: location, appName: appName)
            return CleanupRow(id: group.id, advice: advice, tier: advice.decide ? .decide : CleanupTier(group.category),
                location: location, bytes: group.bytes, ids: Set(group.items.map(\.id)), name: group.name)
        }.sorted { $0.bytes > $1.bytes }
        recommendedIDs = rows.filter { $0.tier == .recommended }.reduce(into: Set<String>()) { $0.formUnion($1.ids) }
        var names: [String] = []
        for entry in runningEntries.sorted(by: { $0.bytes > $1.bytes }) {
            let name = CleanupAdvisor.displayName(entry.ownerBundleID ?? entry.rootURL.lastPathComponent, appName: appName)
            if !names.contains(name) { names.append(name) }
        }
        runningApps = names
    }
    /// Rows by tier. Without a query, small rows beyond the first five fold into one line.
    func tiers(_ query: String) -> [CleanupTierSection] {
        CleanupTier.allCases.compactMap { tier in
            let matching = rows.filter { $0.tier == tier && (query.isEmpty || $0.matches(query)) }
            guard !matching.isEmpty else { return nil }
            var shown = matching, folded: [CleanupRow] = []
            if query.isEmpty {
                shown = matching.enumerated().filter { $0.offset < 5 || $0.element.bytes >= 50_000_000 }.map(\.element)
                folded = Array(matching.dropFirst(shown.count))
                if folded.count < 2 { shown = matching; folded = [] }
            }
            return CleanupTierSection(tier: tier, rows: shown, folded: folded,
                ids: matching.reduce(into: Set<String>()) { $0.formUnion($1.ids) }, bytes: matching.reduce(0) { $0 + $1.bytes })
        }
    }
    func selectedItems(_ selection: Set<String>) -> [CleanupItem] {
        selection.compactMap { itemsByID[$0] }.sorted { (itemOrder[$0.id] ?? 0) < (itemOrder[$1.id] ?? 0) }
    }
    func selectedBytes(_ selection: Set<String>) -> Int64 { selection.reduce(0) { $0 + (itemsByID[$1]?.bytes ?? 0) } }
    func search(_ query: String, category: CleanupCategory?) -> OrdinarySearchResults {
        var result = OrdinarySearchResults()
        for group in groups where category == nil || group.category == category {
            let items = query.isEmpty || group.name.localizedCaseInsensitiveContains(query) ? group.items : group.items.filter { $0.url.path.localizedCaseInsensitiveContains(query) }
            guard !items.isEmpty else { continue }
            result.groups.append(group); result.itemsByGroup[group.id] = Array(items.prefix(300))
            result.selectableIDs.formUnion(groupItemIDs[group.id] ?? [])
        }
        return result
    }
}

struct OrdinarySearchResults: Sendable {
    var groups: [CleanupGroup] = []
    var itemsByGroup: [String: [CleanupItem]] = [:]
    var selectableIDs: Set<String> = []
}

struct CleanupRow: Identifiable, Sendable {
    let id: String
    let advice: CleanupAdvice
    let tier: CleanupTier
    let location: URL
    let bytes: Int64
    let ids: Set<String>
    let name: String
    func matches(_ query: String) -> Bool {
        [advice.title, advice.detail, name, location.path].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct CleanupTierSection: Identifiable, Sendable {
    var id: CleanupTier { tier }
    let tier: CleanupTier
    let rows: [CleanupRow]
    let folded: [CleanupRow]
    let ids: Set<String>
    let bytes: Int64
}

func commonFolder(_ urls: [URL]) -> URL {
    guard var parts = urls.first?.deletingLastPathComponent().pathComponents else { return URL(fileURLWithPath: "/") }
    for url in urls.dropFirst() {
        let other = url.pathComponents
        var count = 0
        while count < parts.count && count < other.count - 1 && parts[count] == other[count] { count += 1 }
        if count < parts.count { parts.removeLast(parts.count - count) }
    }
    return URL(fileURLWithPath: NSString.path(withComponents: parts.isEmpty ? ["/"] : parts))
}

struct CleanupSearchKey: Hashable {
    let scanID: UUID
    let query: String
    var category: CleanupCategory? = nil
}

enum GroupSelectionState {
    case none, mixed, all
    init(ids: Set<String>, selection: Set<String>) {
        let count = ids.intersection(selection).count
        self = count == 0 ? .none : count == ids.count ? .all : .mixed
    }
    static func selecting(_ selected: Bool, ids: Set<String>, in selection: Set<String>) -> Set<String> {
        selected ? selection.union(ids) : selection.subtracting(ids)
    }
}

struct AIResultsIndex {
    let itemsByKind: [AICleanupKind: [AICleanupCandidate]]
    let itemsByID: [String: AICleanupCandidate]
    let itemOrder: [String: Int]
    let relatedIDs: [String: [String]]
    let totalBytes: Int64

    init(_ items: [AICleanupCandidate] = []) {
        itemsByKind = Dictionary(grouping: items, by: \.kind)
        itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        itemOrder = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        totalBytes = items.reduce(0) { $0 + $1.bytes }
        let byTool = Dictionary(grouping: items.filter { $0.kind == .databaseSession }, by: \.tool)
            .mapValues { Dictionary(grouping: $0, by: { $0.conversationID ?? "" }) }
        let order = itemOrder
        var cache: [AITool: [String: [String]]] = [:], related: [String: [String]] = [:]
        for item in items {
            guard let first = item.conversationID else { related[item.id] = [item.id]; continue }
            if let ids = cache[item.tool]?[first] { related[item.id] = ids; continue }
            var queue = [first], seen = Set<String>()
            while let id = queue.popLast() {
                guard seen.insert(id).inserted else { continue }
                for candidate in byTool[item.tool]?[id] ?? [] { queue.append(contentsOf: candidate.relatedConversationIDs) }
            }
            let ids = seen.flatMap { byTool[item.tool]?[$0] ?? [] }.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }.map(\.id)
            cache[item.tool, default: [:]][first] = ids; related[item.id] = ids
        }
        relatedIDs = related
    }
}
