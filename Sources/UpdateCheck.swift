//
//  UpdateCheck.swift
//  Testudo
//

import AppKit

// Opt-in and off by default. When on, it asks GitHub once a day which release
// of this app is newest, and that is all: an ephemeral session (no cookies, no
// cache), no identifiers, nothing about this Mac. A newer version is only
// shown as a link to the releases page; nothing downloads by itself.
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck(repository: "protowaldganger/testudo")

    @Published private(set) var available: String?
    let releasesPage: URL

    private let api: URL
    private var timer: Timer?
    private static let key = "checksForUpdates"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.key) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.key)
            newValue ? start() : stop()
        }
    }

    private init(repository: String) {
        releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
        api = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    func startIfEnabled() {
        if isEnabled { start() }
    }

    private func start() {
        check()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 3600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        available = nil
    }

    private func check() {
        var request = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Testudo", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            DispatchQueue.main.async { self?.received(tag) }
        }.resume()
        session.finishTasksAndInvalidate()
    }

    private func received(_ tag: String) {
        guard isEnabled else { return }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        available = Self.isVersion(latest, newerThan: current) ? latest : nil
    }

    // 1.10 is newer than 1.9; missing parts count as 0.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
