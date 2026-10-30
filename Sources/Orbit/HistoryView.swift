import SwiftUI
import AppKit
import OrbitCore

struct HistoryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                PageHeading(eyebrow: "RECOVERY", title: "清理记录", subtitle: "恢复到原位置。原位置已有文件时会保留现有文件。")
                Button("完成") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
            }
            if state.history.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 30)).foregroundStyle(OrbitTheme.secondary)
                    Text("还没有清理记录")
                    Text("移入废纸篓的文件会记录在这里。").foregroundStyle(OrbitTheme.secondary)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(state.history.sorted { $0.trashedAt > $1.trashedAt }) { record in
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(record.originalURL.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(record.originalURL.path).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).lineLimit(1).truncationMode(.middle).help(record.originalURL.path)
                                    Text(record.trashedAt.formatted(date: .abbreviated, time: .shortened) + " · " + prettyBytes(record.bytes)).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                                }.accessibilityElement(children: .combine)
                                Spacer()
                                if record.state == .restored { Label("已恢复", systemImage: "checkmark").foregroundStyle(OrbitTheme.mint).font(.system(size: 12)) }
                                else if record.state == .trashed { Button("恢复") { state.restore(record) }.buttonStyle(QuietButton()).disabled(state.working || record.trashedURL == nil) }
                                else { Text(record.message ?? "操作未完成").font(.system(size: 11)).foregroundStyle(OrbitTheme.amber).frame(maxWidth: 150) }
                            }.orbitCard().fileContextMenu(record.originalURL, revealURL: record.state == .trashed ? record.trashedURL : nil)
                        }
                    }
                }
            }
        }.padding(30).frame(minWidth: 640, idealWidth: 740, maxWidth: .infinity, minHeight: 440, idealHeight: 540, maxHeight: .infinity).featureSheet()
            .alert(item: $state.notice) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
            }
    }
}
