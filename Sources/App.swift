//
//  App.swift
//  Testudo
//
//  One window and a Settings window. Images arrive by drag and drop, the
//  Add Images command, the Dock icon, Open With and the Finder's Quick
//  Actions menu (Compress with Testudo).
//

import AppKit
import SwiftUI

@main
struct TestudoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Testudo", id: "main") {
            MainView(queue: .shared)
        }
        .defaultSize(width: 640, height: 420)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Images…") { Queue.shared.choose() }
                    .keyboardShortcut("o")
            }
            // There is no help book, so no Help menu item that leads nowhere.
            CommandGroup(replacing: .help) {}
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [
            Queue.Key.quality: 80.0,
            Queue.Key.playSound: true
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        FolderAccess.restore()
        UpdateCheck.shared.startIfEnabled()
    }

    // Dock and Open With.
    func application(_ application: NSApplication, open urls: [URL]) {
        Queue.shared.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Files are rewritten in place, so never quit halfway through one.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Queue.shared.isBusy else { return .terminateNow }
        Queue.shared.cancelWaiting()
        Queue.shared.whenIdle { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    // Finder › Quick Actions › Compress with Testudo (NSServices in Info.plist).
    @objc func compressImages(_ pasteboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        Queue.shared.add(urls)
    }
}
