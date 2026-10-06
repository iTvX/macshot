import Cocoa

extension Notification.Name {
    static let toolbarColorsDidChange = Notification.Name("toolbarColorsDidChange")
}

// Toolbar buttons drawn directly in the OverlayView (not a separate window).
// This avoids window-level z-order issues and matches Flameshot's look.

enum ToolbarButtonAction {
    case tool(AnnotationTool)
    case color
    case sizeDisplay
    case undo
    case redo
    case copy
    case save
    case pin
    case ocr
    case autoRedact
    case beautify
    case beautifyStyle
    case cancel
    case moveSelection
    case adjustSelection
    case delayCapture
    case upload
    case share
    case removeBackground
    case invertColors
    case loupe
    case translate
    case record  // enters recording mode (shows recording toolbar)
    case startRecord  // actually starts recording
    case stopRecord
    case mouseHighlight
    case systemAudio
    case micAudio
    case detach
    case scrollCapture
    case addCapture  // editor only: capture a new region and append to the canvas
    case showKeystrokes
    case webcam
    case recordSettings  // recording mode: open format/FPS/when-done popover
    case effects  // image effects (CIFilter adjustments + presets)
    case toolOptions  // options chip: shows/hides the current tool's options panel
    case more  // the bar's own overflow menu button
}

/// Groups of the single annotation bar, in display order. Hairline dividers
/// separate sections.
enum ToolbarSection: Int, Comparable {
    case leading, tools, style, history, outputs, finish

    static func < (lhs: ToolbarSection, rhs: ToolbarSection) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How a bar control renders.
enum ToolbarButtonStyle: Equatable {
    case icon       // glyph button
    case swatch     // colour dot
    case chip       // value + chevron (tool options)
    case labeled    // glyph + title on a quiet pill (Save)
    case prominent  // glyph + title on a filled pill (Copy, Record)
}

struct ToolbarButton {
    let action: ToolbarButtonAction
    let sfSymbol: String?
    let tooltip: String
    var isSelected: Bool = false
    var tintColor: NSColor = ToolbarLayout.iconColor
    var selectedTintColor: NSColor? = nil  // optional status tint that remains visible while selected
    var bgColor: NSColor? = nil  // for color swatches
    var hasContextMenu: Bool = false  // draw small corner triangle to indicate right-click options
    var section: ToolbarSection = .outputs
    var style: ToolbarButtonStyle = .icon
    var title: String? = nil  // chip / labeled / prominent text
    var prominentColor: NSColor? = nil  // fill of a prominent button; accent when nil
    /// Less frequent actions live in the More menu so the bar stays short.
    var prefersMenu: Bool = false
    /// Never moved into the More menu when the bar must shrink.
    var isEssential: Bool = false
    /// When the bar must shrink, lower priorities move into More first.
    var keepPriority: Int = 0
    /// Separator groups inside the More menu.
    var menuGroup: Int = 0
}

/// What the single bar is showing.
enum ToolbarBarMode {
    case overlay    // in-place annotation after a selection
    case editor     // detached editor window
    case recording  // recording setup before the take starts
}

enum ToolbarCustomAction: Int {
    #if !OFFLINE
    case upload = 1001
    #endif
    case pin = 1002
    case ocr = 1003
    case beautify = 1004
    case removeBackground = 1005
    case autoRedact = 1006
    case reserved1007 = 1007
    case translate = 1008
    case record = 1009
    case scrollCapture = 1010
    case invertColors = 1011
    case share = 1012
    case effects = 1013

    static var allKnownActions: [ToolbarCustomAction] {
        var actions: [ToolbarCustomAction] = []
        #if !OFFLINE
        actions.append(.upload)
        #endif
        actions.append(contentsOf: [
            .pin, .ocr, .beautify, .removeBackground, .autoRedact, .reserved1007,
            .translate, .record, .scrollCapture, .invertColors, .share, .effects,
        ])
        return actions
    }

    /// Settings groups: actions that change the image, and outputs/capture modes.
    static var imageSettingsActions: [ToolbarCustomAction] {
        [.invertColors, .effects, .beautify, .removeBackground]
    }

    static var outputSettingsActions: [ToolbarCustomAction] {
        var actions: [ToolbarCustomAction] = []
        #if !OFFLINE
        actions.append(.upload)
        #endif
        actions.append(contentsOf: [.pin, .ocr, .autoRedact, .translate, .record, .scrollCapture, .share])
        return actions
    }

    var settingsLabel: String {
        switch self {
        #if !OFFLINE
        case .upload: return L("Upload")
        #endif
        case .pin: return L("Pin (floating window)")
        case .ocr: return L("OCR & QR")
        case .beautify: return L("Beautify")
        case .removeBackground: return L("Remove Background")
        case .autoRedact: return L("Auto-Redact sensitive data")
        case .reserved1007: return ""
        case .translate: return L("Translate")
        case .record: return L("Record screen")
        case .scrollCapture: return L("Scroll Capture")
        case .invertColors: return L("Invert Colors")
        case .share: return L("Share")
        case .effects: return L("Adjust (Image Effects)")
        }
    }

    func makeToolbarButton(
        beautifyEnabled: Bool = false,
        translateEnabled: Bool = false,
        effectsActive: Bool = false,
        isRecording: Bool = false,
        isEditorMode: Bool = false
    ) -> ToolbarButton? {
        switch self {
        #if !OFFLINE
        case .upload:
            var button = ToolbarButton(action: .upload, sfSymbol: "icloud.and.arrow.up", tooltip: L("Upload"))
            button.hasContextMenu = true
            return button
        #endif
        case .pin:
            return ToolbarButton(action: .pin, sfSymbol: "pin", tooltip: L("Pin"))
        case .ocr:
            return ToolbarButton(action: .ocr, sfSymbol: "doc.text.viewfinder", tooltip: L("OCR & QR"))
        case .beautify:
            var button = ToolbarButton(action: .beautify, sfSymbol: "sparkles", tooltip: L("Beautify"))
            if beautifyEnabled {
                button.tintColor = ToolbarLayout.accentColor
            }
            return button
        case .removeBackground:
            if #available(macOS 14.0, *) {
                return ToolbarButton(
                    action: .removeBackground,
                    sfSymbol: "person.crop.circle.dashed",
                    tooltip: L("Remove Background")
                )
            }
            return nil
        case .autoRedact, .reserved1007:
            return nil
        case .translate:
            var button = ToolbarButton(action: .translate, sfSymbol: "translate", tooltip: L("Translate"))
            button.isSelected = translateEnabled
            button.hasContextMenu = true
            return button
        case .record:
            guard !isEditorMode else { return nil }
            var button = ToolbarButton(action: .record, sfSymbol: "video.fill", tooltip: L("Record"))
            button.tintColor = ToolbarLayout.iconColor
            return button
        case .scrollCapture:
            guard !isRecording && !isEditorMode else { return nil }
            return ToolbarButton(action: .scrollCapture, sfSymbol: "scroll", tooltip: L("Scroll Capture"))
        case .invertColors:
            return ToolbarButton(
                action: .invertColors,
                sfSymbol: "circle.righthalf.filled.inverse",
                tooltip: L("Invert Colors")
            )
        case .share:
            return ToolbarButton(action: .share, sfSymbol: "square.and.arrow.up", tooltip: L("Share"))
        case .effects:
            var button = ToolbarButton(action: .effects, sfSymbol: "slider.horizontal.3", tooltip: L("Adjust"))
            if effectsActive {
                button.tintColor = ToolbarLayout.accentColor
            }
            return button
        }
    }
}

enum ToolbarActionPreferences {
    static let enabledDefaultsKey = "enabledActions"
    static let knownDefaultsKey = "knownActionTags"

    static var allKnownRawValues: [Int] {
        ToolbarCustomAction.allKnownActions.map(\.rawValue)
    }

    static var defaultEnabledRawValues: [Int] {
        allKnownRawValues
    }

    static func enabledRawValuesAfterMigration() -> [Int]? {
        var enabledActions = UserDefaults.standard.array(forKey: enabledDefaultsKey) as? [Int]
        let knownActionTags = UserDefaults.standard.array(forKey: knownDefaultsKey) as? [Int]
        let newTags = allKnownRawValues.filter { !(knownActionTags ?? []).contains($0) }

        if !newTags.isEmpty {
            if enabledActions == nil {
                enabledActions = allKnownRawValues
            } else if knownActionTags == nil {
                // Upgrading from a version before knownActionTags tracking was added.
            } else {
                enabledActions = enabledActions! + newTags
            }
            UserDefaults.standard.set(enabledActions, forKey: enabledDefaultsKey)
            UserDefaults.standard.set(allKnownRawValues, forKey: knownDefaultsKey)
        }

        return enabledActions
    }

    static func isEnabled(_ action: ToolbarCustomAction, in enabledActions: [Int]?) -> Bool {
        enabledActions == nil || enabledActions!.contains(action.rawValue)
    }
}

class ToolbarLayout {

    // The default palette follows the system; explicit user palettes still win.
    // Provider-backed rather than .systemBlue/.labelColor: withAlphaComponent on a
    // system catalog color freezes it to the appearance current at that call,
    // while these stay dynamic and resolve against the drawing view.
    static let defaultAccentColor = NSColor(name: "MacShotToolbarAccent") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0, green: 122 / 255, blue: 1, alpha: 1)
    }
    static let defaultIconColor = NSColor(name: "MacShotToolbarIcon") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85)
            : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85)
    }
    static let defaultBgColor = NSColor(name: "MacShotToolbarSurface") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.16, alpha: 0.98)
            : NSColor(calibratedWhite: 0.985, alpha: 0.97)
    }

    // User-customizable colors — read from UserDefaults with defaults matching the original look
    static var accentColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarAccentColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultAccentColor
    }
    static var iconColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarIconColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultIconColor
    }
    static var bgColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarBgColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultBgColor
    }
    static var handleColor: NSColor { accentColor }
    static let cornerRadius: CGFloat = 12

    /// Save accent color to UserDefaults.
    static func saveAccentColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarAccentColor")
        }
    }

    /// Save icon color to UserDefaults.
    static func saveIconColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarIconColor")
        }
    }

    /// Appearance matching the toolbar background brightness.
    /// Dark background → `.darkAqua`, light background → `.aqua`.
    static var appearance: NSAppearance? {
        guard UserDefaults.standard.data(forKey: "toolbarBgColor") != nil else { return nil }
        let color = bgColor.usingColorSpace(.deviceRGB) ?? bgColor
        var brightness: CGFloat = 0
        color.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
        return NSAppearance(named: brightness > 0.5 ? .aqua : .darkAqua)
    }

    /// Save background color to UserDefaults.
    static func saveBgColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarBgColor")
        }
    }

    // The fixed dark palette used before the default followed the system.
    static let legacyAccentColor = NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.85, alpha: 1.0)
    static let legacyIconColor = NSColor.white
    static let legacyBgColor = NSColor(white: 0.12, alpha: 1.0)
    static let legacyPaletteMigratedKey = "toolbarLegacyPaletteMigrated"

    /// Colors customized before the adaptive palette were chosen against the
    /// legacy dark toolbar, so a partial customization (say, only the icon
    /// color) would lose its contrast next to system colors. Pin the colors
    /// that were still implicit to their legacy values, once; palettes chosen
    /// afterwards in Settings are left exactly as the user sets them.
    static func migrateLegacyPaletteIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: legacyPaletteMigratedKey) else { return }
        defaults.set(true, forKey: legacyPaletteMigratedKey)
        let keys = ["toolbarAccentColor", "toolbarIconColor", "toolbarBgColor"]
        guard keys.contains(where: { defaults.data(forKey: $0) != nil }) else { return }
        if defaults.data(forKey: "toolbarAccentColor") == nil { saveAccentColor(legacyAccentColor) }
        if defaults.data(forKey: "toolbarIconColor") == nil { saveIconColor(legacyIconColor) }
        if defaults.data(forKey: "toolbarBgColor") == nil { saveBgColor(legacyBgColor) }
    }

    /// Reset all colors to defaults.
    static func resetColors() {
        UserDefaults.standard.removeObject(forKey: "toolbarAccentColor")
        UserDefaults.standard.removeObject(forKey: "toolbarIconColor")
        UserDefaults.standard.removeObject(forKey: "toolbarBgColor")
    }

    /// Enabled annotation tools in bar order. A newly introduced tool is enabled once;
    /// tools the user switched off in Settings stay off.
    static func enabledTools() -> [(tool: AnnotationTool, symbol: String, tooltip: String)] {
        // Track introduced tools in `knownToolRawValues` so user-disabled tools are never re-enabled.
        let allKnownToolRawValues = AnnotationTool.allCases
            .filter { $0 != .select && $0 != .translateOverlay }
            .map { $0.rawValue }
        var enabledRawValues = UserDefaults.standard.array(forKey: "enabledTools") as? [Int]
        let knownToolRawValues = UserDefaults.standard.array(forKey: "knownToolRawValues") as? [Int]
        let newToolRaws = allKnownToolRawValues.filter { !(knownToolRawValues ?? []).contains($0) }
        if !newToolRaws.isEmpty {
            if enabledRawValues == nil {
                // Fresh install: enable everything.
                enabledRawValues = allKnownToolRawValues
            } else if knownToolRawValues == nil {
                // Upgrading from a version before knownToolRawValues tracking was added.
                // Respect the existing enabledTools as-is; just mark all current tools as known.
            } else {
                // Normal upgrade: new tools introduced — add them enabled by default.
                enabledRawValues = (enabledRawValues! + newToolRaws)
            }
            UserDefaults.standard.set(enabledRawValues, forKey: "enabledTools")
            UserDefaults.standard.set(allKnownToolRawValues, forKey: "knownToolRawValues")
        }

        let tools: [(AnnotationTool, String, String)] = [
            (.pencil, "scribble", L("Pencil (Draw)")),
            (.line, "line.diagonal", L("Line")),
            (.arrow, "arrow.up.right", L("Arrow")),
            (.rectangle, "rectangle", L("Rectangle")),
            (.ellipse, "oval", L("Ellipse")),
            (.marker, {
                if #available(macOS 14.0, *) { return "highlighter" }
                return "paintbrush.pointed.fill"
            }(), L("Marker")),
            (.text, "textformat", L("Text")),
            (.number, "1.circle", L("Number")),
            (.pixelate, "_custom.checkerboard", L("Censor (Pixelate / Blur / Solid)")),
            (.highlight, "sun.max", L("Highlight (Spotlight)")),
            (.loupe, "magnifyingglass", L("Magnify (Loupe)")),
            (.stamp, "face.smiling", L("Stamp / Emoji")),
            (.colorSampler, "eyedropper", L("Color Picker")),
            (.measure, "ruler", L("Measure (px)")),
        ]
        return tools
            .filter { enabledRawValues?.contains($0.0.rawValue) ?? true }
            .map { (tool: $0.0, symbol: $0.1, tooltip: $0.2) }
    }

    /// Tools offered from More rather than the bar, unless selected.
    static let menuTools: Set<AnnotationTool> = [.loupe, .stamp, .colorSampler, .measure]

    /// Output actions in bar order. The first three stay on the bar; the rest live in
    /// More, in the listed groups, unless they are active.
    private static let outputOrder: [(action: ToolbarCustomAction, inline: Bool, group: Int)] = {
        var order: [(ToolbarCustomAction, Bool, Int)] = [
            (.beautify, true, 0), (.pin, true, 0), (.ocr, true, 0),
            (.share, false, 2),
        ]
        #if !OFFLINE
        order.append((.upload, false, 2))
        #endif
        order += [
            (.translate, false, 3),
            (.effects, false, 4), (.invertColors, false, 4), (.removeBackground, false, 4),
            (.scrollCapture, false, 5), (.record, false, 5),
        ]
        return order.map { (action: $0.0, inline: $0.1, group: $0.2) }
    }()

    /// Everything the single bar shows for `mode`, in display order.
    /// `toolOptions` is nil when the current tool has no options.
    static func barButtons(
        mode: ToolbarBarMode,
        selectedTool: AnnotationTool = .arrow, selectedColor: NSColor = .systemRed,
        toolOptions: (title: String, isOpen: Bool)? = nil,
        beautifyEnabled: Bool = false, beautifyOptionsShown: Bool = false,
        translateEnabled: Bool = false, effectsActive: Bool = false
    ) -> [ToolbarButton] {
        if mode == .recording { return recordingButtons() }
        let isOverlay = mode == .overlay
        var buttons: [ToolbarButton] = []

        if isOverlay {
            var move = ToolbarButton(
                action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right",
                tooltip: L("Move Selection"))
            move.section = .leading
            move.isEssential = true
            buttons.append(move)
        }

        for (tool, symbol, tip) in enabledTools() {
            var btn = ToolbarButton(action: .tool(tool), sfSymbol: symbol, tooltip: tip)
            btn.section = .tools
            btn.isSelected = tool == selectedTool && !beautifyOptionsShown
            btn.keepPriority = 50
            // Specialist tools wait in More (still one key away) unless in use.
            btn.prefersMenu = menuTools.contains(tool) && tool != selectedTool
            buttons.append(btn)
        }

        var colorBtn = ToolbarButton(action: .color, sfSymbol: nil, tooltip: L("Color"))
        colorBtn.bgColor = selectedColor
        colorBtn.section = .style
        colorBtn.style = .swatch
        colorBtn.isEssential = true
        buttons.append(colorBtn)
        if let toolOptions {
            var chip = ToolbarButton(action: .toolOptions, sfSymbol: "chevron.down", tooltip: L("Tool Options"))
            chip.section = .style
            chip.style = .chip
            chip.title = toolOptions.title
            chip.isSelected = toolOptions.isOpen
            chip.isEssential = true
            buttons.append(chip)
        }

        for (action, symbol, tip) in [(ToolbarButtonAction.undo, "arrow.uturn.backward", L("Undo")),
                                      (.redo, "arrow.uturn.forward", L("Redo"))] {
            var button = ToolbarButton(action: action, sfSymbol: symbol, tooltip: tip)
            button.section = .history
            button.keepPriority = 40
            buttons.append(button)
        }

        if isOverlay {
            var editor = ToolbarButton(
                action: .detach, sfSymbol: "arrow.up.forward.app", tooltip: L("Open in Editor Window"))
            editor.prefersMenu = true
            editor.menuGroup = 1
            buttons.append(editor)
        }
        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
        for (index, entry) in outputOrder.enumerated() {
            guard ToolbarActionPreferences.isEnabled(entry.action, in: enabledActions),
                  var button = entry.action.makeToolbarButton(
                      beautifyEnabled: beautifyEnabled, translateEnabled: translateEnabled,
                      effectsActive: effectsActive, isEditorMode: !isOverlay)
            else { continue }
            if entry.action == .beautify { button.isSelected = beautifyOptionsShown }
            let isActive = button.isSelected || (entry.action == .beautify && beautifyEnabled)
                || (entry.action == .effects && effectsActive)
            button.prefersMenu = !entry.inline && !isActive
            button.menuGroup = entry.group
            button.keepPriority = 30 - index
            buttons.append(button)
        }

        if isOverlay {
            var cancel = ToolbarButton(action: .cancel, sfSymbol: "xmark", tooltip: L("Cancel"))
            cancel.section = .finish
            cancel.isEssential = true
            buttons.append(cancel)
        }
        let saveTooltip: String = {
            switch SaveActionPreference.current {
            case .saveToFolder:
                return "\(L("Save to")) \(URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent)"
            case .askWhereToSave:
                return L("Ask where to save")
            }
        }()
        var save = ToolbarButton(action: .save, sfSymbol: "square.and.arrow.down", tooltip: saveTooltip)
        save.hasContextMenu = true
        save.section = .finish
        save.style = .labeled
        save.title = L("Save")
        save.isEssential = true
        buttons.append(save)
        var copy = ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: L("Copy"))
        copy.section = .finish
        copy.style = .prominent
        copy.title = L("Copy")
        copy.isEssential = true
        buttons.append(copy)
        return buttons
    }

    /// Recording setup: options for the take, then Cancel and the Record button.
    private static func recordingButtons() -> [ToolbarButton] {
        var buttons: [ToolbarButton] = []
        var move = ToolbarButton(
            action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right",
            tooltip: L("Move Selection"))
        move.section = .leading
        move.isEssential = true
        buttons.append(move)

        let mouseHighlightOn = UserDefaults.standard.bool(forKey: "recordMouseHighlight")
        var mouseBtn = ToolbarButton(
            action: .mouseHighlight, sfSymbol: "cursorarrow.click.2", tooltip: L("Highlight Mouse Clicks"))
        mouseBtn.isSelected = mouseHighlightOn
        buttons.append(mouseBtn)

        let keystrokesOn = UserDefaults.standard.bool(forKey: "recordKeystroke")
        var keystrokeBtn = ToolbarButton(
            action: .showKeystrokes, sfSymbol: "keyboard", tooltip: L("Show Keystrokes"))
        keystrokeBtn.isSelected = keystrokesOn
        keystrokeBtn.hasContextMenu = true
        buttons.append(keystrokeBtn)

        let audioOn = UserDefaults.standard.bool(forKey: "recordSystemAudio")
        var audioBtn = ToolbarButton(
            action: .systemAudio, sfSymbol: audioOn ? "speaker.wave.2.fill" : "speaker.slash",
            tooltip: L("Record System Audio"))
        audioBtn.isSelected = audioOn
        buttons.append(audioBtn)

        let micOn = UserDefaults.standard.bool(forKey: "recordMicAudio")
        var micBtn = ToolbarButton(
            action: .micAudio, sfSymbol: micOn ? "mic.fill" : "mic.slash", tooltip: L("Record Microphone"))
        micBtn.isSelected = micOn
        micBtn.hasContextMenu = true
        buttons.append(micBtn)

        let webcamOn = UserDefaults.standard.bool(forKey: "recordWebcam")
        let webcamSymbol: String = {
            if #available(macOS 14.0, *) {
                return webcamOn ? "web.camera.fill" : "web.camera"
            }
            return webcamOn ? "camera.fill" : "camera"
        }()
        var webcamBtn = ToolbarButton(action: .webcam, sfSymbol: webcamSymbol, tooltip: L("Webcam Overlay"))
        webcamBtn.isSelected = webcamOn
        webcamBtn.hasContextMenu = true
        buttons.append(webcamBtn)

        buttons.append(ToolbarButton(
            action: .recordSettings, sfSymbol: "gearshape", tooltip: L("Recording Settings")))
        for index in 1..<buttons.count { buttons[index].keepPriority = 60 - index }

        var cancel = ToolbarButton(action: .stopRecord, sfSymbol: "xmark", tooltip: L("Cancel Recording"))
        cancel.section = .finish
        cancel.isEssential = true
        buttons.append(cancel)
        var start = ToolbarButton(action: .startRecord, sfSymbol: "record.circle", tooltip: L("Start Recording"))
        start.section = .finish
        start.style = .prominent
        start.title = L("Record")
        start.prominentColor = .systemRed
        start.isEssential = true
        buttons.append(start)
        return buttons
    }
}
