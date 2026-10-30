import AppKit
import SwiftUI

@MainActor
final class CleanScreenController {
    private var windows: [NSWindow] = []
    private var monitor: Any?
    private var inactiveObserver: NSObjectProtocol?
    private var timeout: Task<Void, Never>?
    private var cursorHidden = false
    var isActive: Bool { !windows.isEmpty }

    func show(seconds: Int = 30) {
        stop()
        for screen in NSScreen.screens {
            let window = CleaningWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .black
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: VStack(spacing: 18) {
                Image(systemName: "hand.raised.fill").font(.system(size: 36)).foregroundStyle(.gray)
                Text("现在可以清洁屏幕").font(.system(size: 24, weight: .medium))
                Text("按 Esc 退出 · \(seconds) 秒后自动结束").font(.system(size: 14)).foregroundStyle(.gray)
            }.foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black))
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        inactiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        NSCursor.hide(); cursorHidden = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            if event.type == .keyDown && (event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q")) {
                self?.stop()
                return event.keyCode == 53 ? nil : event
            }
            return nil
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
            if !Task.isCancelled { self?.stop() }
        }
    }
    func stop() {
        timeout?.cancel(); timeout = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver); self.inactiveObserver = nil }
        for window in windows { window.orderOut(nil); window.close() }
        windows = []
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }
}

private final class CleaningWindow: NSWindow { override var canBecomeKey: Bool { true } }
