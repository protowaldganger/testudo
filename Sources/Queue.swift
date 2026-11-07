//
//  Queue.swift
//  Testudo
//
//  The list of files and the work on them. One job per active core; each job
//  reads a file, compresses it in C, and writes the result only if it got
//  smaller: over the original, or as a new file next to it. When everything
//  dropped in one go is done, Basso plays.
//

import AppKit
import Observation
import UniformTypeIdentifiers

@Observable
final class FileItem: Identifiable {
    enum Status: Equatable {
        case waiting, working, smaller, noGain, unsupported
        case failed(String)

        var isPending: Bool { self == .waiting || self == .working }
    }

    let id = UUID()
    let url: URL
    let name: String
    var status = Status.waiting
    var output: URL?          // the new file, when originals are kept
    var before = 0
    var after = 0

    init(url: URL) {
        self.url = url
        name = url.lastPathComponent
    }

    var saved: Int { status == .smaller ? before - after : 0 }
}

@Observable
final class Queue {
    static let shared = Queue()

    enum Key {
        static let lossy = "lossy"
        static let quality = "quality"
        static let keepMetadata = "keepMetadata"
        static let playSound = "playSound"
        static let keepOriginals = "keepOriginals"
    }

    private(set) var items: [FileItem] = []
    private(set) var pending = 0

    @ObservationIgnored private let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Testudo"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount
        return queue
    }()
    @ObservationIgnored private var idleHandlers: [() -> Void] = []

    var isBusy: Bool { pending > 0 }

    // MARK: Adding

    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.prompt = "Compress"
        panel.message = UserDefaults.standard.bool(forKey: Key.keepOriginals)
            ? "Choose images or folders. Smaller copies are saved next to them."
            : "Choose images or folders. Files are replaced with smaller versions."
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    // Folders are walked off the main thread; only images inside them count.
    // Files given one by one are always listed, so a wrong type says so.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let files = Self.files(in: urls)
            DispatchQueue.main.async { self.enqueue(files) }
        }
    }

    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "jpe", "webp"]

    private static func files(in urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls where url.isFileURL {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isFolder else { files.append(url.standardizedFileURL); continue }
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let file = walker?.nextObject() as? URL {
                if extensions.contains(file.pathExtension.lowercased()),
                   !file.deletingPathExtension().lastPathComponent.hasSuffix(Copy.suffix) {
                    files.append(file.standardizedFileURL)
                }
            }
        }
        return files
    }

    private func enqueue(_ urls: [URL]) {
        let options = currentOptions()
        // Saving copies needs the folder, not just the file, so ask for any
        // folder Testudo may not write in yet. Once per folder, remembered.
        if UserDefaults.standard.bool(forKey: Key.keepOriginals) {
            FolderAccess.prepare(Set(urls.map { $0.deletingLastPathComponent() }))
        }
        var known = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        for url in urls {
            if let item = known[url] {
                if !item.status.isPending { schedule(item, options) }
            } else {
                let item = FileItem(url: url)
                items.append(item)
                known[url] = item
                schedule(item, options)
            }
        }
    }

    // MARK: List

    func compressAgain() {
        let options = currentOptions()
        for item in items where !item.status.isPending { schedule(item, options) }
    }

    func clear() {
        items.removeAll { !$0.status.isPending }
    }

    func remove(_ ids: Set<FileItem.ID>) {
        items.removeAll { ids.contains($0.id) && !$0.status.isPending }
    }

    func reveal(_ ids: Set<FileItem.ID>) {
        let urls = items.filter { ids.contains($0.id) }.map { $0.output ?? $0.url }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    var summary: String {
        if pending > 0 {
            return pending == 1 ? "1 image left" : "\(pending) images left"
        }
        guard !items.isEmpty else { return "" }
        let before = items.reduce(0) { $0 + $1.before }
        let saved = items.reduce(0) { $0 + $1.saved }
        guard saved > 0, before > 0 else { return "Nothing to save" }
        let percent = (Double(saved) / Double(before)).formatted(.percent.precision(.fractionLength(0...1)))
        return "Saved \(Int64(saved).formatted(.byteCount(style: .file))), \(percent)"
    }

    // MARK: Work

    private func currentOptions() -> tt_options {
        let defaults = UserDefaults.standard
        return tt_options(lossy: defaults.bool(forKey: Key.lossy) ? 1 : 0,
                          quality: Int32(defaults.double(forKey: Key.quality).rounded()),
                          keep_metadata: defaults.bool(forKey: Key.keepMetadata) ? 1 : 0)
    }

    private func schedule(_ item: FileItem, _ options: tt_options) {
        item.status = .waiting
        item.output = nil
        pending += 1
        let url = item.url
        let copy = UserDefaults.standard.bool(forKey: Key.keepOriginals) ? Copy.url(for: url) : nil
        workers.addOperation { [weak self] in
            DispatchQueue.main.async { if item.status == .waiting { item.status = .working } }
            let outcome = Compressor.run(url, options, saveAs: copy)
            DispatchQueue.main.async { self?.finish(item, outcome) }
        }
    }

    private func finish(_ item: FileItem, _ outcome: Compressor.Outcome) {
        switch outcome {
        case .smaller(let before, let after, let output):
            item.before = before; item.after = after; item.output = output; item.status = .smaller
        case .noGain(let size):
            item.before = size; item.after = size; item.status = .noGain
        case .unsupported:
            item.status = .unsupported
        case .failed(let reason):
            item.status = .failed(reason)
        case .cancelled:
            item.status = .failed("Cancelled")
        }
        pending -= 1
        if pending == 0 { batchFinished() }
    }

    private func batchFinished() {
        if UserDefaults.standard.bool(forKey: Key.playSound) {
            NSSound(named: "Basso")?.play()
        }
        let handlers = idleHandlers
        idleHandlers = []
        handlers.forEach { $0() }
    }

    func whenIdle(_ handler: @escaping () -> Void) {
        if pending == 0 { handler() } else { idleHandlers.append(handler) }
    }

    // Quitting: let the files being written finish, skip the rest.
    func cancelWaiting() {
        Compressor.cancelled = true
    }
}

// The C side does all the work; this moves bytes between disk and it.
enum Compressor {
    enum Outcome {
        case smaller(Int, Int, URL?), noGain(Int), unsupported, failed(String), cancelled
    }

    nonisolated(unsafe) static var cancelled = false

    // With `copy`, the original is left alone and the result goes there.
    static func run(_ url: URL, _ options: tt_options, saveAs copy: URL?) -> Outcome {
        if cancelled { return .cancelled }
        let manager = FileManager.default
        let data: Data
        let stamp: Date?
        do {
            stamp = try manager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            data = try Data(contentsOf: url)
        } catch {
            return .failed("Can’t read the file")
        }

        var output: UnsafeMutablePointer<UInt8>?
        var size = 0
        let status = data.withUnsafeBytes { raw in
            tt_compress(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, options, &output, &size)
        }
        defer { tt_free(output) }

        if status == TT_UNSUPPORTED { return .unsupported }
        if status == TT_FAILED { return .failed("Damaged or unusual image") }
        guard status == TT_SMALLER, let output, size > 0, size < data.count else { return .noGain(data.count) }

        let result = Data(bytesNoCopy: output, count: size, deallocator: .none)
        if let copy {
            do {
                try result.write(to: copy, options: .atomic)
            } catch {
                return .failed("No permission to save here")
            }
            return .smaller(data.count, size, copy)
        }

        // Someone saved over it meanwhile: theirs wins.
        let now = try? manager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        guard now == stamp else { return .failed("Changed while compressing") }

        // Written in place, so the file keeps its permissions, tags, dates
        // and Finder comments, and sandboxed access to it is enough.
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: result)
            try handle.truncate(atOffset: UInt64(size))
        } catch {
            return .failed("Can’t write the file")
        }
        return .smaller(data.count, size, nil)
    }
}

// Copies sit next to the original: photo.png becomes photo-compressed.png.
// Compressing the same original again replaces its earlier copy.
enum Copy {
    static let suffix = "-compressed"

    static func url(for original: URL) -> URL {
        let name = original.deletingPathExtension().lastPathComponent + suffix
        return original.deletingLastPathComponent()
            .appendingPathComponent(name)
            .appendingPathExtension(original.pathExtension)
    }
}

// The sandbox lets Testudo change a file you hand it, but making a new file
// beside it needs the folder. Testudo asks for a folder the first time it
// needs one and keeps a bookmark, so it never asks for that folder again.
enum FolderAccess {
    private static let key = "folderBookmarks"

    static func restore() {
        for data in UserDefaults.standard.array(forKey: key) as? [Data] ?? [] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
            }
        }
    }

    static func prepare(_ folders: Set<URL>) {
        for folder in folders.sorted(by: { $0.path < $1.path }) where !canWrite(in: folder) {
            request(folder)
        }
    }

    private static func canWrite(in folder: URL) -> Bool {
        let probe = folder.appendingPathComponent(".testudo-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    private static func request(_ folder: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = folder
        panel.prompt = "Allow"
        panel.message = "To save compressed copies next to your originals, allow Testudo to use \u{201C}\(folder.lastPathComponent)\u{201D}."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        guard let data = try? chosen.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        var saved = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        saved.append(data)
        UserDefaults.standard.set(saved, forKey: key)
    }
}
