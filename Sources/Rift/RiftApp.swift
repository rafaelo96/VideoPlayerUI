import SwiftUI
import AppKit

extension Notification.Name {
    static let riftOpenURLs = Notification.Name("RiftOpenURLs")
}

@main
struct RiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Rift") {
            if CommandLine.arguments.count > 1 {
                EmptyView()
                    .frame(width: 1, height: 1)
            } else {
                ContentView()
                    .frame(minWidth: 780, minHeight: 480)
                    .onAppear {
                        AppDelegate.bringPlayerWindowToFront()
                    }
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var pendingOpenURLs: [URL] = []
    private var cliWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Self.setApplicationIcon()
        Self.bringPlayerWindowToFront()

        guard CommandLine.arguments.count > 1 else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Rift"
        window.center()
        window.contentView = NSHostingView(rootView: ContentView())
        window.makeKeyAndOrderFront(nil)
        cliWindow = window
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Self.enqueueOpenURLs(urls)
        Self.bringPlayerWindowToFront()
    }

    @MainActor
    static func takePendingOpenURLs() -> [URL] {
        defer { pendingOpenURLs.removeAll() }
        return pendingOpenURLs
    }

    @MainActor
    private static func enqueueOpenURLs(_ urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls)
        NotificationCenter.default.post(name: .riftOpenURLs, object: nil, userInfo: ["urls": urls])
    }

    @MainActor
    static func setApplicationIcon() {
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }

    @MainActor
    static func bringPlayerWindowToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
