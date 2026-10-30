import Foundation
import CryptoKit
import Darwin
import OrbitCore

/// Used only by the explicit local diagnostic launch flags. No file contents are inspected by comparison.
enum ScanDiagnostics {
    private struct Manifest: Decodable { let targets: [Target] }
    private struct Target: Decodable {
        let id: String
        let path: String
        let section: String
        let title: String
        let shownBytes: Int64?
        let selectedBytes: Int64?
    }

    static func write(_ scan: UnifiedCleanupScan, to url: URL) {
        let sections: [[String: Any]] = UnifiedCleanupSection.allCases.map { section in
            ["section": section.rawValue, "title": section.title, "bytes": scan.bytes(in: section),
             "isPartial": scan.partialSections.contains(section), "entries": scan.entries.filter { $0.section == section }.count]
        }
        let rows: [[String: Any]] = scan.entries.map {
            ["id": $0.id, "section": $0.section.rawValue, "path": $0.url.path, "title": $0.title,
             "bytes": $0.bytes.map { $0 as Any } ?? NSNull(), "countedBytes": $0.countedBytes.map { $0 as Any } ?? NSNull(),
             "fileCount": $0.fileCount, "isPartial": $0.isPartial, "detail": $0.detail, "handling": $0.handling.rawValue]
        }
        save(["schemaVersion": 1, "pid": getpid(), "bundlePath": Bundle.main.bundleURL.path,
              "capturedAt": ISO8601DateFormatter().string(from: Date()), "countedBytes": scan.countedBytes,
              "countedFiles": scan.files.count, "ordinaryCandidateBytes": scan.ordinary.totalBytes,
              "aiCandidateBytes": scan.ai.candidateBytes, "isPartial": scan.isPartial, "selectedItems": 0,
              "cleanupPerformed": false, "sections": sections, "entries": rows, "issues": issueRows(scan.issues)], to: url)
    }

    static func writeAccess(_ entries: [ReadAccessEntry], to url: URL) {
        let rows: [[String: Any]] = entries.map {
            ["path": $0.target.url.path, "title": $0.target.title, "status": $0.status.rawValue,
             "issues": issueRows($0.issue.map { [$0] } ?? [])]
        }
        save(["pid": getpid(), "bundlePath": Bundle.main.bundleURL.path, "capturedAt": ISO8601DateFormatter().string(from: Date()), "entries": rows], to: url)
    }

    static func compare(_ scan: UnifiedCleanupScan, manifest: URL, output: URL) async {
        do {
            let data = try Data(contentsOf: manifest)
            let input = try JSONDecoder().decode(Manifest.self, from: data)
            let roots = input.targets.filter { $0.path.hasPrefix("/") }.map { ExtendedCleanupRoot(url: URL(fileURLWithPath: $0.path), title: $0.title) }
            let policy = ExtendedCleanupPolicy(systemRoots: roots.sorted { $0.url.path.count > $1.url.path.count }, trashRoots: [], maximumEntries: 800_000, timeLimit: 60)
            let reference = await ExtendedCleanupScanner(policy: policy).scan()
            let targets = Set(input.targets.map(\.path))
            let unifiedIDs = Set(scan.files.map(\.identity))
            var measured: [String: Int64] = [:], covered: [String: Int64] = [:]
            var counts: [String: Int] = [:], coveredCounts: [String: Int] = [:]
            for file in reference.files {
                var path = file.url.path
                let included = unifiedIDs.contains("\(file.device):\(file.inode)")
                while path != "/" {
                    if targets.contains(path) {
                        measured[path, default: 0] += file.logicalBytes; counts[path, default: 0] += 1
                        if included { covered[path, default: 0] += file.logicalBytes; coveredCounts[path, default: 0] += 1 }
                    }
                    path = (path as NSString).deletingLastPathComponent
                }
            }
            let entries = Dictionary(reference.items.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
            var aliases: [String: String] = [:], pathAlias: [String: String] = [:]
            for target in input.targets.sorted(by: { (measured[$0.path] ?? -1) > (measured[$1.path] ?? -1) }) {
                var value = stat()
                if lstat(target.path, &value) == 0 {
                    let key = "\(value.st_dev):\(value.st_ino)"
                    if let prior = aliases[key] { pathAlias[target.path] = prior } else { aliases[key] = target.path }
                }
            }
            let rows: [[String: Any]] = input.targets.map { target in
                let path = pathAlias[target.path] ?? target.path
                let entry = entries[target.path]
                let bytes = measured[path] ?? entry?.logicalBytes
                let coveredBytes = covered[path] ?? 0
                let incomplete = (entry?.isPartial ?? true) || reference.issues.contains {
                    $0.path == target.path || $0.path.hasPrefix(target.path + "/") || target.path.hasPrefix($0.path + "/")
                }
                let status: String
                if entry?.access == .denied { status = "permissionDenied" }
                else if entry?.access == .missing { status = "missing" }
                else if bytes == nil { status = "unknown" }
                else if incomplete { status = "referenceIncomplete" }
                else if bytes == 0 && (coveredCounts[path] ?? 0) == 0 { status = "empty" }
                else if coveredBytes == bytes && coveredCounts[path] == counts[path] { status = "covered" }
                else if coveredBytes > 0 { status = "partlyCovered" }
                else { status = "notInUnifiedResult" }
                return ["id": target.id, "path": target.path, "section": target.section, "title": target.title,
                        "moleShownBytes": target.shownBytes.map { $0 as Any } ?? NSNull(),
                        "moleSelectedBytes": target.selectedBytes.map { $0 as Any } ?? NSNull(),
                        "referenceLogicalBytes": bytes.map { $0 as Any } ?? NSNull(),
                        "referenceFileCount": counts[path] ?? entry?.fileCount ?? 0,
                        "unifiedCoveredBytes": coveredBytes, "unifiedCoveredFiles": coveredCounts[path] ?? 0,
                        "coverage": status, "referenceAccess": entry?.access.rawValue ?? "unknown",
                        "referenceIsPartial": incomplete, "aliasOf": pathAlias[target.path].map { $0 as Any } ?? NSNull(),
                        "issues": issueRows(entry?.issues ?? [])]
            }
            save(["schemaVersion": 1, "pid": getpid(), "bundlePath": Bundle.main.bundleURL.path,
                  "capturedAt": ISO8601DateFormatter().string(from: Date()), "manifestPath": manifest.path,
                  "manifestSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                  "referenceIsPartial": reference.isPartial, "referenceVisitedEntries": reference.visitedEntries,
                  "referenceUniqueBytes": reference.files.reduce(Int64(0)) { $0 + $1.logicalBytes },
                  "cleanupPerformed": false, "rows": rows, "issues": issueRows(reference.issues)], to: output)
        } catch {
            save(["error": error.localizedDescription, "cleanupPerformed": false], to: output)
        }
    }

    private static func issueRows(_ issues: [CleanupScanIssue]) -> [[String: Any]] {
        issues.map { ["kind": $0.kind.rawValue, "path": $0.path, "message": $0.message,
                      "errorDomain": $0.errorDomain.map { $0 as Any } ?? NSNull(), "errorCode": $0.errorCode.map { $0 as Any } ?? NSNull(),
                      "underlyingPOSIXCode": $0.underlyingPOSIXCode.map { $0 as Any } ?? NSNull()] }
    }
    private static func save(_ value: [String: Any], to url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }
}
