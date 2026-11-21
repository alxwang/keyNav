import AppKit
import ScreenCaptureKit

/// Live window captures via ScreenCaptureKit plus an in-memory LRU of snapshots, so
/// minimized / hidden windows (which can't be captured live) still get a picture.
@MainActor
final class ThumbnailService {
    private var cache: [CGWindowID: NSImage] = [:]
    private var lru: [CGWindowID] = []
    private var pendingSnapshot: Task<Void, Never>?
    private let store: SettingsStore
    private let maxPixels: CGFloat = 640

    init(store: SettingsStore) { self.store = store }

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func cached(_ id: CGWindowID) -> NSImage? { id == 0 ? nil : cache[id] }

    func clear() { cache.removeAll(); lru.removeAll() }

    private func remember(_ id: CGWindowID, _ image: NSImage) {
        guard store.settings.snapshotCache, id != 0 else { return }
        cache[id] = image
        lru.removeAll { $0 == id }
        lru.append(id)
        while lru.count > max(1, store.settings.cacheSize) {
            cache.removeValue(forKey: lru.removeFirst())
        }
    }

    /// Captures on-screen windows live; calls `update` on the main actor as images arrive.
    func captureLive(_ windows: [WindowInfo], update: @escaping (CGWindowID, NSImage) -> Void) {
        let ids = Set(windows.filter { $0.state == .onScreen && $0.id != 0 }.map(\.id))
        guard hasPermission, !ids.isEmpty else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            else { return }
            let targets = content.windows.filter { ids.contains($0.windowID) }
            await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
                for w in targets {
                    group.addTask { (w.windowID, await Self.capture(w, maxPixels: 640)) }
                }
                for await (id, image) in group {
                    guard let image else { continue }
                    self.remember(id, image)
                    update(id, image)
                }
            }
        }
    }

    /// Snapshot an app's on-screen windows into the cache (e.g. right after it deactivates).
    func snapshotApp(pid: pid_t) {
        guard store.settings.snapshotCache, hasPermission, pid != getpid() else { return }
        pendingSnapshot?.cancel()
        pendingSnapshot = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled,
                  let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            else { return }
            let targets = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width >= 40 && $0.frame.height >= 40
            }
            for w in targets {
                guard !Task.isCancelled else { return }
                if let image = await Self.capture(w, maxPixels: 640) { self.remember(w.windowID, image) }
            }
        }
    }

    nonisolated private static func capture(_ window: SCWindow, maxPixels: CGFloat) async -> NSImage? {
        let f = window.frame
        guard f.width > 0, f.height > 0 else { return nil }
        let scale = min(1, maxPixels / max(f.width, f.height)) * 2
        let config = SCStreamConfiguration()
        config.width = max(1, Int(f.width * min(scale, 2)))
        config.height = max(1, Int(f.height * min(scale, 2)))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
