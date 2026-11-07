<img src=".github/icon.png" width="128" alt="">

# Testudo

Makes PNG, JPEG and WebP images smaller. Drop them in and get smaller versions, either in place or as new files.

Made by protowaldganger.

## Install

1. Download `Testudo.dmg` from [the latest release](../../releases/latest), open it and drag Testudo onto Applications.
2. Open it. macOS warns that it cannot verify the developer, because the app is not notarized. Open System Settings › Privacy & Security, scroll down and click Open Anyway.

Requires macOS 27 on Apple silicon. About 1 MB.

## Use

- Drop images or folders on the window or the Dock icon, or press ⌘O.
- In the Finder, right-click images and choose Quick Actions › Compress with Testudo.
- A short sound plays when everything you added at once is done. It uses a sound built into macOS, so the app ships none.
- Files are only replaced when the result is smaller. Double-click a row to show the file in the Finder.
- To keep your originals, set Settings › Compressed images to Save as new files. photo.png then gets a smaller copy, photo-compressed.png, beside it. The first time Testudo saves in a folder you only dropped single files from, it asks once for permission to use that folder.
- On a Force Touch trackpad, the quality slider clicks at each step.

By default compression is lossless: every pixel stays the same. Turn on Lossy compression in Settings for much smaller PNG and WebP files. JPEGs are then re-encoded only if they were saved above the chosen quality.

Color profiles and rotation are always kept. Camera details, location and editing history are removed unless you turn on Keep metadata.

## What it uses

| Format | Lossless | Lossy |
|---|---|---|
| PNG | Best filter per image, recompressed with libdeflate, smallest exact color type | libimagequant palette |
| JPEG | mozjpeg: optimized, progressive, no quality loss | mozjpeg re-encode |
| WebP | Metadata removed without re-encoding, lossless files re-encoded losslessly | libwebp re-encode |

Animated WebP files are left as they are.

## Private by design

Images never leave your Mac. Every file is compressed locally. No analytics, no tracking, no crash reports, no accounts.

It is sandboxed, so it can only reach the images and folders you give it. All it stores is your settings and, if you save new files, which folders you allowed.

The only thing that ever goes online is Check for updates, and it is off by default. When on, it asks GitHub once a day which release is newest, with no cookies, no cache and nothing about you or your Mac, and shows a link if there is a newer one. Nothing downloads or installs by itself. With it off, Testudo makes no connections at all.

## Build

Requires Xcode.

```
zsh build.sh
```

This makes `build/Testudo.app` and `build/Testudo.dmg`.

## Uninstall

```
rm -rf /Applications/Testudo.app
rm -rf ~/Library/Containers/com.protowaldganger.testudo
```

## License

GPL v3, because it includes libimagequant. See LICENSE and THIRD-PARTY-NOTICES.md.
