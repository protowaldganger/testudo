//
//  SettingsView.swift
//  Testudo
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(Queue.Key.lossy) private var lossy = false
    @AppStorage(Queue.Key.quality) private var quality = 80.0
    @AppStorage(Queue.Key.keepMetadata) private var keepMetadata = false
    @AppStorage(Queue.Key.playSound) private var playSound = true
    @AppStorage(Queue.Key.keepOriginals) private var keepOriginals = false
    @AppStorage(Queue.Key.trashOriginals) private var trashOriginals = false
    @AppStorage(Queue.Key.extraEffort) private var extraEffort = false
    @ObservedObject private var updates = UpdateCheck.shared

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Lossy compression", isOn: $lossy)
                    LabeledContent("Quality") {
                        HStack(spacing: 10) {
                            Slider(value: $quality, in: 50...95, step: 5)
                                // A tick on the trackpad at every step.
                                .sensoryFeedback(.alignment, trigger: quality)
                            Text("\(Int(quality))")
                                .monospacedDigit()
                                .frame(width: 22, alignment: .trailing)
                        }
                        .frame(width: 200)
                    }
                    .disabled(!lossy)
                    Toggle("Extra effort for PNG", isOn: $extraEffort)
                } footer: {
                    Text("Lossless keeps every pixel. Lossy makes PNG, WebP and HEIC files far smaller, and re-encodes a JPEG only when it was saved above this quality. Extra effort packs PNGs with Zopfli: usually 3 to 8% smaller again, but many times slower.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Compressed images", selection: $keepOriginals) {
                        Text("Replace the originals").tag(false)
                        Text("Save as new files").tag(true)
                    }
                    if !keepOriginals {
                        Toggle("Move originals to the Trash", isOn: $trashOriginals)
                    }
                } footer: {
                    Text(keepOriginals
                         ? "The original stays untouched. photo.png gets a smaller copy, photo-compressed.png, in the same folder."
                         : trashOriginals
                         ? "The original goes to the Trash, so Put Back in the Finder brings it back. The first time in a folder, Testudo asks once for permission to use it."
                         : "The original is replaced, but only once the smaller version is complete and only if it is smaller.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Keep metadata", isOn: $keepMetadata)
                } footer: {
                    Text("Color profiles and rotation are always kept. When off, camera details, location and editing history are removed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Play sound when done", isOn: $playSound)
                    Toggle("Check for updates", isOn: Binding(get: { updates.isEnabled },
                                                              set: { updates.isEnabled = $0 }))
                    if let available = updates.available {
                        LabeledContent("Testudo \(available) is available") {
                            Link("Download", destination: updates.releasesPage)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Byline(name: "Testudo")
                .padding(.bottom, 16)
        }
        .frame(width: 460)
        .tint(Style.accent)
        .fixedSize(horizontal: false, vertical: true)
    }
}
