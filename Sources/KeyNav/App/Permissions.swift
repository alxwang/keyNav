import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published var accessibility = AXIsProcessTrusted()
    @Published var screenRecording = CGPreflightScreenCaptureAccess()
    @Published var screenRecordingRequested = false
    private var timer: Timer?
    private var pollers = 0

    func refresh() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
    }

    func startPolling() {
        pollers += 1
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { PermissionManager.shared.refresh() }
        }
    }

    func stopPolling() {
        pollers = max(0, pollers - 1)
        if pollers == 0 { timer?.invalidate(); timer = nil }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) {
            Self.openPrivacyPane("Privacy_Accessibility")
        }
    }

    func requestScreenRecording() {
        screenRecordingRequested = true
        if !CGRequestScreenCaptureAccess() {
            Self.openPrivacyPane("Privacy_ScreenCapture")
        }
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

struct PermissionRows: View {
    @ObservedObject var perms: PermissionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(ok: perms.accessibility, title: "Accessibility", required: true,
                detail: "Needed to read windows and controls, focus windows, and click.",
                action: "Grant Access…") { perms.requestAccessibility() }
            row(ok: perms.screenRecording, title: "Screen Recording", required: false,
                detail: "Optional. Shows thumbnails of covered, minimized, and hidden windows. Without it, app icons are shown.",
                action: "Grant Access…") { perms.requestScreenRecording() }
            if perms.screenRecordingRequested && !perms.screenRecording {
                HStack {
                    Text("After enabling Screen Recording, KeyNav must be relaunched.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Relaunch KeyNav") { PermissionManager.relaunch() }
                }
            }
        }
        .onAppear { perms.refresh(); perms.startPolling() }
        .onDisappear { perms.stopPolling() }
    }

    private func row(ok: Bool, title: String, required: Bool, detail: String, action: String,
                     perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : (required ? "exclamationmark.circle.fill" : "circle"))
                .foregroundStyle(ok ? .green : (required ? .orange : .secondary))
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title + (required ? "" : " (optional)")).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if ok {
                Text("Granted").foregroundStyle(.green)
            } else {
                Button(action, action: perform)
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var perms: PermissionManager
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "keyboard").font(.system(size: 36))
                VStack(alignment: .leading) {
                    Text("Welcome to KeyNav").font(.title.bold())
                    Text("Keyboard navigation for windows and controls.").foregroundStyle(.secondary)
                }
            }
            PermissionRows(perms: perms)
            Text("Tip: if KeyNav already appears in the Accessibility list but doesn't work, remove it with “–” and add it again.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(perms.accessibility ? "Done" : "Later") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
