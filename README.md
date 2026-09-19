# macshot

<p align="center">
  <img src="assets/logo.svg" alt="macshot logo" width="200"/>
</p>

<p align="center">
  <b>The most feature-rich open-source screenshot tool on macOS.</b><br>
  <br>
  19+ annotation tools, screen recording with a full video editor, OCR + translation,<br>
  auto-redact PII, scroll capture, beautify — all native, all free.
</p>

<p align="center">
  <a href="https://github.com/iTvX/macshot/releases/latest">Download</a> · <a href="https://github.com/iTvX/macshot/blob/main/CHANGELOG.md">Changelog</a> · <a href="https://github.com/iTvX/macshot/blob/main/PRIVACY.md">Privacy</a> · <a href="https://github.com/iTvX/macshot/blob/main/SECURITY.md">Security</a>
</p>

<p align="center">
  <img src="assets/preview.png" alt="macshot demo" width="700"/>
</p>

<p align="center">
  <img src="assets/preview-editor.png" alt="macshot video editor — timeline with cut, speed, freeze, zoom and censor effects" width="700"/>
</p>

---

## About this fork

This GPL-3.0 fork tracks the [upstream macshot project](https://github.com/sw33tLie/macshot)
and adds alternative keyboard shortcuts and application-level capture exclusions. Users can choose applications in
**Settings → Capture → Capture Exclusions**; matching applications are removed at the
ScreenCaptureKit source before screenshots or recordings are produced. Content behind an
excluded application's windows appears naturally in the result. The system menu bar, Dock,
desktop icons, and wallpaper remain visible.

The fork uses its own bundle identifier, Developer ID release signature, Sparkle signing
key, GitHub Releases, and update feed. Builds downloaded from this repository update only
from this repository.

The current source integrates upstream **4.2.2-beta.5** and its accessibility-state
restoration fix (`43d5ae4852`). This includes element snapping, automatic selection
adjustment, keyboard-layout fixes, recording cleanup, and the newer upload/editor options.
Element snapping requires Accessibility permission when first selected with Tab.

Screenshot copying defaults to image data for compatibility with Teams, websites, and
remote desktops. To paste screenshots as files in Finder on macOS 26 or earlier, enable
**Settings → Capture → Enable Finder clipboard compatibility**. Leave this option off
when the destination app has trouble reading clipboard files.

---

### Why macshot?

- **Capture & annotate in one flow** — select a region, draw arrows/text/shapes/blur, copy to clipboard. One hotkey, zero friction.
- **Screen recording with built-in editor** — record any area or full screen as MP4/GIF with system audio + microphone. Audio merge dialog with per-track volume control. Trim and export without leaving the app.
- **Scroll capture** — select a region and scroll. macshot stitches it into one seamless tall (or wide) image automatically.
- **Upload anywhere** — one-click upload to Google Drive, imgbb, or any S3-compatible service (Cloudflare R2, AWS S3, MinIO, etc.). Link copied to clipboard instantly.
- **Lightweight & native** — lives in your menu bar. Built with Swift and AppKit, not a web browser in disguise.
- **40 languages** — English, 中文, 日本語, 한국어, Deutsch, Français, Español, Italiano, Português, العربية, हिन्दी, and 29 more. Auto-detects your system language.

---

## Install

Download `MacShot.zip` from this fork's [latest release](https://github.com/iTvX/macshot/releases/latest),
extract it, and move `macshot.app` to `/Applications`. The upstream Homebrew cask installs
the upstream edition and does not contain this fork's capture-exclusion feature.

---

## Quick Start

1. Launch macshot — it appears in your menu bar
2. Press `Cmd+Shift+5` to capture
3. Drag to select, annotate with the toolbar, press `Cmd+C` to copy
4. Press `Esc` to cancel

### Exclude an application from captures

1. Open **Settings → Capture**.
2. Under **Capture Exclusions**, click **Add Application…**.
3. Select one or more `.app` bundles.
4. Keep the selected applications running and capture normally.

The exclusion applies to full-screen and area screenshots, window capture, delayed capture,
scroll capture, and screen recording. Attempting to snap directly to an excluded application's
window is blocked. The feature requires macOS 14 or later and intentionally fails closed if a
filtered capture cannot be produced.

---

<details>
<summary><b>All Features</b></summary>

### Capture
- **Instant capture** — global hotkey freezes your screen, select any region
- **Window snap** — hover over a window and click to capture it exactly; `Tab` toggles snap, `F` for full screen
- **Resolution & aspect presets** — set an exact pixel size or lock an aspect ratio (1:1, 4:3, 16:9, 9:16, …) before or after selecting; editable width/height fields
- **Boundary snap** — selection edges snap to strong color edges (UI lines, window borders) while dragging or resizing; hold `Option` to bypass
- **Scroll capture** — auto-detects vertical or horizontal scrolling, stitches with Apple Vision, live preview panel beside the capture region
- **Capture delay** — 3/5/10/30 second countdown before capture, set via menu bar. Escape to cancel.
- **Multi-monitor** — captures all screens simultaneously; drag a selection across screens for a stitched image
- **Quick save** — `Cmd+Shift+S` to select and save/copy instantly without annotation. Enter key also saves/copies based on preference.
- **Quick OCR** — `Cmd+Shift+T` to select and extract text instantly

### Annotation Tools
- **Arrow** — 5 styles: single, thick/banner, double, open, tail; flip direction toggle; right-click to add anchor points for complex curves
- **Shapes** — rectangle and ellipse with 3 fill modes (stroke, stroke+fill, fill), corner radius slider
- **Text** — rich formatting (bold/italic/underline/strikethrough), resizable text box, left/center/right alignment, background fill & outline colors, click to re-edit
- **Pencil & Marker** — freeform drawing with optional smoothing; smart marker mode snaps to text lines via OCR
- **Numbered markers** — auto-incrementing (1/I/A/a formats), with optional pointer cone
- **Stamp / Emoji** — 21 quick emojis, 100+ in categorized picker, or load any image
- **Censor (Pixelate / Blur / Solid / Erase)** — unified redaction tool with 4 modes: pixelate, Gaussian blur, solid color fill, or smart erase that samples surrounding colors for invisible content removal. Auto-redact PII (emails, phones, credit cards, SSNs, API keys), auto-detect faces and people, or draw in "Text Only" mode to censor just the text in a region
- **Measure** — pixel ruler with px/pt toggle; hold `1` or `2` for auto-measure
- **Loupe** — 2x magnifier
- **Highlight (spotlight)** — drag a region to keep it bright while dimming the rest; adjustable dim strength and solid/dashed border
- **Color sampler** — eyedropper to pick any color; right-click to copy hex; auto-saves to custom palette slots
- **Space to reposition** — hold Space while drawing to move the shape without changing its size
- **Rotation** — rotate shapes via handle, Shift for 90° snaps
- **Click-to-select** — click any annotation to select it, then edit properties (stroke, style, fill), drag to move, resize via handles, rotate, or delete — all without switching tools

### Screen Recording
- **MP4 (H.264)** up to 120fps or **GIF** (5/10/15fps)
- **System audio capture** — toggle on/off, excludes macshot's own sounds
- **Microphone recording** — record voice narration alongside screen capture (permission requested on first use)
- **Mouse click highlights** — visual ripple on clicks during recording
- **Selection border** — visible capture region outline during recording
- **Menu bar stop button** — stop recording from the menu bar icon (appears even if icon is hidden)
- **Quick settings popover** — change format, FPS, and post-recording action on the fly without opening Preferences
- **Video editor** — trim timeline, mute/strip audio, play/pause, save (with Save As), upload, reveal in Finder

### Output & Upload
- **Formats** — PNG, JPEG, HEIC, WebP, AVIF with quality slider
- **Google Drive** — sign in once, uploads to a private folder (defaults to "macshot", configurable in Settings)
- **imgbb** — anonymous image hosting with shareable links
- **S3-compatible** — upload to Cloudflare R2, AWS S3, MinIO, DigitalOcean Spaces, Backblaze B2, etc.
- **Retina downscale** — optional 1x export for smaller files
- **sRGB color profile** — optional embedding for cross-display consistency

### Editor Window
- Standalone resizable window with full annotation tools, beautify preview
- **Add Capture** — capture additional screen regions and compose them into a single image, drag to reposition
- **Paste image** — `Cmd+V` drops a clipboard image into the canvas as a draggable layer
- Crop (with rule-of-thirds grid), flip H/V, zoom 0.1x–8x
- Top bar with pixel dimensions, zoom dropdown (presets, fit canvas, zoom in/out)

### Beautify
- macOS window frame with traffic lights, shadow, and gradient background
- 30 gradient styles including 7 mesh gradients (macOS 15+), adjustable padding/corner radius/shadow

### Image Effects (Adjust)
- Non-destructive CIFilter adjustments: Brightness, Contrast, Saturation, Sharpness
- 8 presets: Noir, Mono, Sepia, Chrome, Fade, Instant, Vivid
- Works independently or combined with Beautify
- Live preview in the overlay

### Other
- **OCR & QR** — extract text with Apple Vision (auto-detects all languages on macOS 13+), auto-copy to clipboard, translate to 30+ languages, Google AI Search; also reads QR codes with open/copy/scan actions
- **Invert colors** — one-click color inversion, apply twice to revert
- **Background removal** — Apple Vision foreground mask (macOS 14+)
- **Pin to screen** — floating always-on-top window
- **Floating thumbnail** — auto-dismiss preview with Copy/Save/Pin/Edit/Upload
- **Screenshot history with editable annotations** — menu bar submenu + drop-down history panel (`Cmd+Shift+H`). Re-open any capture in the editor with live annotations preserved — edit, then press Done to save back. Drag-and-drop, Quick Look, and right-click actions
- **QR & barcode detection** — inline Open/Copy actions
- **Snap alignment guides** — annotations snap to midlines and edges
- **Liquid Glass theme** (macOS 26 Tahoe) — render toolbars, popovers, and HUDs as Apple's translucent Liquid Glass material
- **Custom menu bar icon** — use the default, a built-in preset, or any SF Symbol
- **Auto-updates** via Sparkle

</details>

<details>
<summary><b>Keyboard Shortcuts</b></summary>

**Global hotkeys** (configurable in Preferences)

In **Settings → Shortcuts → Keyboard Shortcuts**, every action supports a primary
shortcut and an optional **Alternative**. Either combination triggers the same action,
and each can be set or cleared independently. Existing users' shortcuts are preserved.
New installations use the defaults below; Reset restores the shipped binding,
including Quick Capture's alternative. See [factory settings](FACTORY_SETTINGS.md)
for the full initial configuration and upgrade behavior.
Duplicate assignments are rejected without replacing the previous shortcut. Press **Esc**
to cancel recording. The menu displays the primary shortcut, or the alternative when the
primary is empty. Overlay / Editor shortcuts continue to use one binding per action.

| Shortcut | Action |
|---|---|
| `Cmd+Shift+5` | Capture Area |
| Unassigned | Capture Full Screen |
| `Option+S` or `Cmd+Shift+4` | Quick Capture (instant save) |
| `Cmd+Shift+3` | Capture OCR (copy text to clipboard) |
| Unassigned | Record Area |
| `Cmd+Shift+H` | Show History Panel |

**General** (during capture)

| Shortcut | Action |
|---|---|
| `Enter` | Confirm (save or copy based on preference) |
| `Cmd+C` | Copy to clipboard |
| `Cmd+S` | Save to file |
| `Cmd+Z` / `Cmd+Shift+Z` | Undo / Redo |
| `Cmd+0` | Reset zoom to 1x |
| `Esc` | Cancel / close popover |
| `Delete` | Remove selected annotation |
| `Tab` | Toggle window snap mode |
| `F` | Capture full screen (snap mode) |
| `Shift` (while drawing) | Constrain to straight lines / perfect shapes |
| `Space` (while drawing) | Reposition shape without changing size |
| `Right-click` on line/arrow | Add anchor point for multi-point curves |

**Tool shortcuts** (active after selecting a region — customizable in Preferences > Shortcuts)

| Key | Tool |
|---|---|
| `A` | Arrow |
| `L` | Line |
| `P` | Pencil |
| `M` | Marker |
| `R` | Rectangle |
| `O` | Ellipse |
| `T` | Text |
| `N` | Number |
| `B` | Censor (Pixelate/Blur) |
| `H` | Highlight (spotlight) |
| `I` | Color Sampler |
| `G` | Stamp / Emoji |
| `S` | Select & Edit |
| `E` | Open in Editor |

</details>

---

## Permissions

macshot requires **Screen Recording** permission. macOS will prompt you on first capture.

---

## Donations

Thanks for thinking about it, but macshot doesn't take donations. I make this in my free time and I'm happy to keep it that way, so there's no "buy me a coffee" or sponsorship link.

If you'd like to help out, starring the repo, reporting bugs, or contributing is more than enough. Thank you! 🙏

---

## Requirements

macOS 12.3 (Monterey) or later.

## License

[GPLv3](LICENSE)
