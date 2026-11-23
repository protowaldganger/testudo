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
import ImageIO
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
        static let trashOriginals = "trashOriginals"
        static let extraEffort = "extraEffort"
    }

    static var replacesViaTrash: Bool {
        let defaults = UserDefaults.standard
        return !defaults.bool(forKey: Key.keepOriginals) && defaults.bool(forKey: Key.trashOriginals)
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
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic, .heif]
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

    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "jpe", "webp", "heic", "heif"]

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
        // Saving copies, or a new file while the original goes to the Trash,
        // needs the folder, not just the file, so ask for any folder Testudo
        // may not write in yet. Once per folder, remembered.
        if UserDefaults.standard.bool(forKey: Key.keepOriginals) || Self.replacesViaTrash {
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
                          keep_metadata: defaults.bool(forKey: Key.keepMetadata) ? 1 : 0,
                          extra_effort: defaults.bool(forKey: Key.extraEffort) ? 1 : 0)
    }

    private func schedule(_ item: FileItem, _ options: tt_options) {
        item.status = .waiting
        item.output = nil
        pending += 1
        let url = item.url
        let copy = UserDefaults.standard.bool(forKey: Key.keepOriginals) ? Copy.url(for: url) : nil
        let viaTrash = Self.replacesViaTrash
        workers.addOperation { [weak self] in
            DispatchQueue.main.async { if item.status == .waiting { item.status = .working } }
            let outcome = Compressor.run(url, options, saveAs: copy, trashOriginal: viaTrash)
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
    // With `trashOriginal`, the original goes to the Trash and the result
    // takes its place, so the Finder's Put Back undoes it.
    static func run(_ url: URL, _ options: tt_options, saveAs copy: URL?, trashOriginal: Bool) -> Outcome {
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
        var produced = 0
        let status = data.withUnsafeBytes { raw in
            tt_compress(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, options, &output, &produced)
        }
        defer { tt_free(output) }

        let result: Data
        if status == TT_UNSUPPORTED {
            // Not one of the C engine's formats: maybe a photo from an iPhone.
            switch Heic.compress(data, options) {
            case .notHeic: return .unsupported
            case .unsupported: return .unsupported
            case .noGain: return .noGain(data.count)
            case .smaller(let smaller): result = smaller
            }
        } else {
            if status == TT_FAILED { return .failed("Damaged or unusual image") }
            guard status == TT_SMALLER, let output, produced > 0, produced < data.count else { return .noGain(data.count) }
            result = Data(bytesNoCopy: output, count: produced, deallocator: .none)
        }
        let size = result.count

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

        if trashOriginal {
            if let problem = Replace.viaTrash(url, with: result) { return .failed(problem) }
            return .smaller(data.count, size, nil)
        }

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

// Replacing a file so that the original can come back: the new version is
// written beside it under a hidden name, the original goes to the Trash, and
// the new one takes its name. Its Finder tags, comments, permissions and
// creation date are carried over first. If any step fails, the original
// stays where it was, or is safe in the Trash with the new file next to it.
enum Replace {
    static func viaTrash(_ url: URL, with data: Data) -> String? {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).testudo-\(UUID().uuidString)")
        do {
            try data.write(to: temporary)
        } catch {
            return "No permission to save here"
        }
        copyAttributes(from: url, to: temporary)
        do {
            try manager.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try? manager.removeItem(at: temporary)
            return "Can’t move the original to the Trash"
        }
        do {
            try manager.moveItem(at: temporary, to: url)
        } catch {
            return "Original is in the Trash; the new file is hidden beside it"
        }
        return nil
    }

    private static func copyAttributes(from source: URL, to target: URL) {
        let manager = FileManager.default
        if let attributes = try? manager.attributesOfItem(atPath: source.path) {
            var kept: [FileAttributeKey: Any] = [:]
            for key in [FileAttributeKey.posixPermissions, .creationDate, .extensionHidden] {
                if let value = attributes[key] { kept[key] = value }
            }
            try? manager.setAttributes(kept, ofItemAtPath: target.path)
        }
        // Extended attributes hold the Finder tags and comments.
        source.withUnsafeFileSystemRepresentation { from in
            target.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return }
                let length = listxattr(from, nil, 0, XATTR_NOFOLLOW)
                guard length > 0 else { return }
                var names = [CChar](repeating: 0, count: length)
                guard listxattr(from, &names, length, XATTR_NOFOLLOW) == length else { return }
                var start = 0
                for index in 0..<length where names[index] == 0 {
                    let name = names.withUnsafeBufferPointer { String(cString: $0.baseAddress! + start) }
                    start = index + 1
                    let size = getxattr(from, name, nil, 0, 0, XATTR_NOFOLLOW)
                    guard size >= 0 else { continue }
                    var value = [UInt8](repeating: 0, count: max(size, 1))
                    let read = getxattr(from, name, &value, size, 0, XATTR_NOFOLLOW)
                    guard read == size else { continue }
                    setxattr(to, name, value, size, 0, XATTR_NOFOLLOW)
                }
            }
        }
    }
}

// HEIC and HEIF, the iPhone's photo format, through macOS's own codec.
// Turning them into JPEGs would roughly double their size, so they stay HEIC:
// - Lossless: the image data is copied untouched and only the metadata is
//   left out (camera details, location). Nothing to do with Keep metadata on.
// - Lossy: the photo is encoded again at the chosen quality, and kept only
//   when that saves at least a tenth, since every new encoding costs a little
//   detail. HDR, depth and Portrait data come along.
enum Heic {
    enum Result { case notHeic, unsupported, noGain, smaller(Data) }

    private static let types: Set<String> = ["public.heic", "public.heif", "public.heics"]

    // The extra images a photo can carry beside the picture itself.
    private static let auxiliary: [CFString] = [
        kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap,
        kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
        kCGImageAuxiliaryDataTypePortraitEffectsMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte
    ]

    static func compress(_ data: Data, _ options: tt_options) -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), types.contains(type as String) else { return .notHeic }
        // Bursts and live sequences hold several images; leave them alone.
        guard CGImageSourceGetCount(source) == 1 else { return .unsupported }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] ?? 1

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type, 1, nil) else { return .unsupported }

        if options.lossy != 0 {
            var changes: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: Double(options.quality) / 100
            ]
            if options.keep_metadata == 0 {
                for dictionary in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                                   kCGImagePropertyIPTCDictionary, kCGImagePropertyMakerAppleDictionary,
                                   kCGImagePropertyExifAuxDictionary] {
                    changes[dictionary] = kCFNull
                }
                changes[kCGImagePropertyOrientation] = orientation
            }
            CGImageDestinationAddImageFromSource(destination, source, 0, changes as CFDictionary)
            for kind in auxiliary {
                if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kind) {
                    CGImageDestinationAddAuxiliaryDataInfo(destination, kind, info)
                }
            }
            guard CGImageDestinationFinalize(destination) else { return .unsupported }
            return output.length < data.count * 9 / 10 ? .smaller(output as Data) : .noGain
        }

        guard options.keep_metadata == 0 else { return .noGain }
        let changes: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageDestinationOrientation: orientation
        ]
        guard CGImageDestinationCopyImageSource(destination, source, changes as CFDictionary, nil) else { return .noGain }
        return output.length < data.count ? .smaller(output as Data) : .noGain
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
