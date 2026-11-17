# Galley App Icon – Fraktur Final

A red Fraktur G on paper: a rubricated initial, as in early printed books.

- Letter: G from **UnifrakturMaguntia** by J. "MasterBinary" Kuehn, licensed under the SIL Open Font License 1.1 (free to use in logos and app icons). The outline is the font's own, unchanged.
- Red: #B9301D
- Paper: #FBFAF8 → #F2F1ED (top to bottom)

## macOS

- `Galley.icns` – the finished Mac icon with every size from 16 to 1024 px (standard and Retina). Put it in your app bundle, or try it on any app via Finder → Get Info → drag onto the small icon.
- `AppIcon.appiconset/` – the same ten images plus `Contents.json`. In Xcode, drag it into your asset catalog in place of the existing AppIcon; Xcode builds the .icns when it builds the app.
- `Galley App Icon 1024.png` – 1024 px, transparent corners, for the Mac App Store and presentations.

## Source

- `Galley App Icon.svg` – the editable master on the macOS icon grid (824 px rounded square inside 1024, corner radius 185). Layers: paper, letter-g, rim.
- `Galley Artwork, Full Bleed.svg` – the same artwork filling the whole square, without the rounded shape or shadow.

## Icon Composer Layers

Two full-bleed 1024 px layers for Apple's Icon Composer (macOS 26 icon format): paper and letter. Icon Composer adds the rounded shape, edge and shadows, and can derive dark and tinted versions.

## Mark

The G on its own, transparent background, as SVG and PNG: red, black (for light backgrounds) and white (for dark backgrounds). For the website, documentation, social avatars and print.

## Web

- `favicon.ico` (16, 32, 48 px) and `favicon.svg` – browser tab icons
- `apple-touch-icon.png` (180 px) – home screen bookmark on iPhone and iPad; square, iOS rounds the corners
- `icon-192.png`, `icon-512.png` – web app manifest icons
- `Galley Artwork 1024 (square).png` – square artwork for store tiles and social cards

```html
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
```
