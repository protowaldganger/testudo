//
//  MainView.swift
//  Testudo
//
//  A drop target when empty, a table when not. The toolbar adds, compresses
//  the list again with the current settings, and clears it; the subtitle
//  says what is left or what was saved.
//

import SwiftUI

struct MainView: View {
    let queue: Queue
    @State private var selection = Set<FileItem.ID>()
    @State private var targeted = false
    @AppStorage(Queue.Key.keepOriginals) private var keepOriginals = false

    var body: some View {
        Group {
            if queue.items.isEmpty {
                ContentUnavailableView {
                    Label("Drop Images Here", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text(keepOriginals
                         ? "PNG, JPEG and WebP, or folders of them. Smaller copies are saved next to the originals."
                         : "PNG, JPEG and WebP, or folders of them. Each file is replaced with a smaller version.")
                } actions: {
                    Button("Choose Images…") { queue.choose() }
                }
            } else {
                table
            }
        }
        .frame(minWidth: 480, minHeight: 280)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        .navigationSubtitle(queue.summary)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { queue.choose() } label: {
                    Label("Add Images", systemImage: "plus")
                }
                .help("Add images or folders")

                Button { queue.compressAgain() } label: {
                    Label("Compress Again", systemImage: "arrow.clockwise")
                }
                .help("Compress the list again with the current settings")
                .disabled(queue.items.isEmpty || queue.isBusy)

                Button { queue.clear(); selection.removeAll() } label: {
                    Label("Clear List", systemImage: "xmark")
                }
                .help("Clear the list. Files stay as they are.")
                .disabled(queue.items.isEmpty || queue.isBusy)
            }
        }
    }

    private var table: some View {
        Table(queue.items, selection: $selection) {
            TableColumn("") { item in
                StatusIcon(status: item.status)
            }
            .width(18)

            TableColumn("Name") { item in
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
            }

            TableColumn("Size") { item in
                Text(item.status == .smaller || item.status == .noGain
                     ? Int64(item.after).formatted(.byteCount(style: .file)) : "")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 80, max: 120)

            TableColumn("Saved") { item in
                Text(savings(item))
                    .monospacedDigit()
                    .foregroundStyle(item.status == .smaller ? HierarchicalShapeStyle.primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 64, max: 100)
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            Button("Show in Finder") { queue.reveal(ids) }
            Button("Remove from List") { queue.remove(ids) }
        } primaryAction: { ids in
            queue.reveal(ids)
        }
        .onDeleteCommand {
            queue.remove(selection)
            selection.removeAll()
        }
    }

    private func savings(_ item: FileItem) -> String {
        switch item.status {
        case .smaller:
            return (Double(item.before - item.after) / Double(max(item.before, 1)))
                .formatted(.percent.precision(.fractionLength(1)))
        case .noGain: return "0%"
        case .unsupported: return "Not an image"
        case .failed(let reason): return reason
        case .waiting, .working: return ""
        }
    }
}

private struct StatusIcon: View {
    let status: FileItem.Status

    var body: some View {
        switch status {
        case .waiting:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Waiting")
        case .working:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Compressing")
        case .smaller:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Smaller")
        case .noGain:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Already as small as it gets")
        case .unsupported, .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityLabel("Not compressed")
        }
    }
}
