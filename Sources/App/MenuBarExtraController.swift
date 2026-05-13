import AppKit
import Foundation

@MainActor
final class MenuBarExtraController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu(title: "cmux")
    private let onShowGlobalSearch: (NSStatusBarButton, (() -> Void)?) -> Void
    private let onShowMainWindow: () -> Void
    private let onOpenTaskManager: () -> Void
    private let onOpenPreferences: () -> Void
    private let onQuitApp: () -> Void
    private let buildHintTitle: String?

    private let stateHintItem = NSMenuItem(title: String(localized: "statusMenu.noUnread", defaultValue: "No unread notifications"), action: nil, keyEquivalent: "")
    private let buildHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let globalSearchItem = NSMenuItem(title: String(localized: "statusMenu.searchAllWindows", defaultValue: "Search All Windows..."), action: nil, keyEquivalent: "")
    private let showMainWindowItem = NSMenuItem(title: String(localized: "statusMenu.showCmux", defaultValue: "Show cmux"), action: nil, keyEquivalent: "")
    private let taskManagerItem = NSMenuItem(title: String(localized: "statusMenu.taskManager", defaultValue: "Task Manager..."), action: nil, keyEquivalent: "")
    private let preferencesItem = NSMenuItem(title: String(localized: "menu.preferences", defaultValue: "Preferences…"), action: nil, keyEquivalent: "")
    private let quitItem = NSMenuItem(title: String(localized: "menu.quitCmux", defaultValue: "Quit cmux"), action: nil, keyEquivalent: "")

    init(
        onShowGlobalSearch: @escaping (NSStatusBarButton, (() -> Void)?) -> Void,
        onShowMainWindow: @escaping () -> Void,
        onOpenTaskManager: @escaping () -> Void,
        onOpenPreferences: @escaping () -> Void,
        onQuitApp: @escaping () -> Void
    ) {
        self.onShowGlobalSearch = onShowGlobalSearch
        self.onShowMainWindow = onShowMainWindow
        self.onOpenTaskManager = onOpenTaskManager
        self.onOpenPreferences = onOpenPreferences
        self.onQuitApp = onQuitApp
        self.buildHintTitle = MenuBarBuildHintFormatter.menuTitle()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        buildMenu()
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.image = MenuBarIconRenderer.makeImage(unreadCount: 0)
            button.toolTip = "cmux"
            button.target = self
            button.action = #selector(statusItemButtonAction(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        refreshUI()
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        stateHintItem.isEnabled = false
        menu.addItem(stateHintItem)
        if let buildHintTitle {
            buildHintItem.title = buildHintTitle
            buildHintItem.isEnabled = false
            menu.addItem(buildHintItem)
        }

        menu.addItem(.separator())

        globalSearchItem.target = self
        globalSearchItem.action = #selector(globalSearchAction)
        menu.addItem(globalSearchItem)

        showMainWindowItem.target = self
        showMainWindowItem.action = #selector(showMainWindowAction)
        menu.addItem(showMainWindowItem)

        taskManagerItem.target = self
        taskManagerItem.action = #selector(taskManagerAction)
        menu.addItem(taskManagerItem)

        preferencesItem.target = self
        preferencesItem.action = #selector(preferencesAction)
        menu.addItem(preferencesItem)

        menu.addItem(.separator())

        quitItem.target = self
        quitItem.action = #selector(quitAction)
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshUI()
    }

    func refreshForDebugControls() {
        refreshUI()
    }

    func removeFromMenuBar() {
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func refreshUI() {
        let displayedUnreadCount = 0

        stateHintItem.title = String(localized: "statusMenu.ready", defaultValue: "Ready")
        showMainWindowItem.isHidden = !MenuBarOnlySettings.shouldShowMainWindowMenuItem()

        applyShortcut(KeyboardShortcutSettings.menuShortcut(for: .globalSearch), to: globalSearchItem)

        if let button = statusItem.button {
            button.image = MenuBarIconRenderer.makeImage(unreadCount: displayedUnreadCount)
            button.toolTip = "cmux"
        }
    }

    private func applyShortcut(_ shortcut: StoredShortcut, to item: NSMenuItem) {
        guard let keyEquivalent = shortcut.menuItemKeyEquivalent else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    @objc private func statusItemButtonAction(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            onShowGlobalSearch(sender, nil)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .rightMouseUp || flags.contains(.control) {
            refreshUI()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        } else {
            onShowGlobalSearch(sender, nil)
        }
    }

    @discardableResult
    func toggleGlobalSearchPalette(onDismiss: (() -> Void)? = nil) -> Bool {
        guard let button = statusItem.button else { return false }
        onShowGlobalSearch(button, onDismiss)
        return true
    }

    @objc private func globalSearchAction() {
        toggleGlobalSearchPalette()
    }

    @objc private func showMainWindowAction() {
        onShowMainWindow()
    }

    @objc private func taskManagerAction() {
        onOpenTaskManager()
    }

    @objc private func preferencesAction() {
        onOpenPreferences()
    }

    @objc private func quitAction() {
        onQuitApp()
    }
}

enum MenuBarBadgeLabelFormatter {
    static func badgeText(for unreadCount: Int) -> String? {
        guard unreadCount > 0 else { return nil }
        if unreadCount > 9 {
            return "9+"
        }
        return String(unreadCount)
    }
}

enum MenuBarBuildHintFormatter {
    static func menuTitle(
        appName: String = defaultAppName(),
        isDebugBuild: Bool = _isDebugAssertConfiguration()
    ) -> String? {
        guard isDebugBuild else { return nil }
        let normalized = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "cmux DEV"
        guard normalized.hasPrefix(prefix) else { return "Build: DEV" }

        let suffix = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if suffix.isEmpty {
            return "Build: DEV (untagged)"
        }
        return "Build Tag: \(suffix)"
    }

    private static func defaultAppName() -> String {
        let bundle = Bundle.main
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
            return name
        }
        return ProcessInfo.processInfo.processName
    }
}

enum MenuBarExtraSettings {
    static let showInMenuBarKey = "showMenuBarExtra"
    static let defaultShowInMenuBar = true

    static func showsMenuBarExtra(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showInMenuBarKey) == nil {
            return defaultShowInMenuBar
        }
        return defaults.bool(forKey: showInMenuBarKey)
    }

    static func shouldInstallMenuBarExtra(defaults: UserDefaults = .standard) -> Bool {
        MenuBarOnlySettings.isEnabled(defaults: defaults) || showsMenuBarExtra(defaults: defaults)
    }
}

enum MenuBarOnlySettings {
    static let menuBarOnlyKey = "menuBarOnly"
    static let defaultMenuBarOnly = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: menuBarOnlyKey) == nil {
            return defaultMenuBarOnly
        }
        return defaults.bool(forKey: menuBarOnlyKey)
    }

    static func activationPolicy(defaults: UserDefaults = .standard) -> NSApplication.ActivationPolicy {
        isEnabled(defaults: defaults) ? .accessory : .regular
    }

    static func shouldShowMainWindowMenuItem(defaults: UserDefaults = .standard) -> Bool {
        isEnabled(defaults: defaults)
    }

    static func applyActivationPolicy(defaults: UserDefaults = .standard, application: NSApplication = .shared) {
        let targetPolicy = activationPolicy(defaults: defaults)
        guard application.activationPolicy() != targetPolicy else { return }
        application.setActivationPolicy(targetPolicy)
    }
}

struct MenuBarBadgeRenderConfig {
    var badgeRect: NSRect
    var singleDigitFontSize: CGFloat
    var multiDigitFontSize: CGFloat
    var singleDigitYOffset: CGFloat
    var multiDigitYOffset: CGFloat
    var singleDigitXAdjust: CGFloat
    var multiDigitXAdjust: CGFloat
    var textRectWidthAdjust: CGFloat
}

enum MenuBarIconDebugSettings {
    static let previewEnabledKey = "menubarDebugPreviewEnabled"
    static let previewCountKey = "menubarDebugPreviewCount"
    static let badgeRectXKey = "menubarDebugBadgeRectX"
    static let badgeRectYKey = "menubarDebugBadgeRectY"
    static let badgeRectWidthKey = "menubarDebugBadgeRectWidth"
    static let badgeRectHeightKey = "menubarDebugBadgeRectHeight"
    static let singleDigitFontSizeKey = "menubarDebugSingleDigitFontSize"
    static let multiDigitFontSizeKey = "menubarDebugMultiDigitFontSize"
    static let singleDigitYOffsetKey = "menubarDebugSingleDigitYOffset"
    static let multiDigitYOffsetKey = "menubarDebugMultiDigitYOffset"
    static let singleDigitXAdjustKey = "menubarDebugSingleDigitXAdjust"
    static let legacySingleDigitXAdjustKey = "menubarDebugTextRectXAdjust"
    static let multiDigitXAdjustKey = "menubarDebugMultiDigitXAdjust"
    static let textRectWidthAdjustKey = "menubarDebugTextRectWidthAdjust"

    static let defaultBadgeRect = NSRect(x: 5.38, y: 6.43, width: 10.75, height: 11.58)
    static let defaultSingleDigitFontSize: CGFloat = 6.7
    static let defaultMultiDigitFontSize: CGFloat = 6.7
    static let defaultSingleDigitYOffset: CGFloat = 0.6
    static let defaultMultiDigitYOffset: CGFloat = 0.6
    static let defaultSingleDigitXAdjust: CGFloat = -1.1
    static let defaultMultiDigitXAdjust: CGFloat = 2.42
    static let defaultTextRectWidthAdjust: CGFloat = 1.8

    static func displayedUnreadCount(actualUnreadCount: Int, defaults: UserDefaults = .standard) -> Int {
        guard defaults.bool(forKey: previewEnabledKey) else { return actualUnreadCount }
        let value = defaults.integer(forKey: previewCountKey)
        return max(0, min(value, 99))
    }

    static func badgeRenderConfig(defaults: UserDefaults = .standard) -> MenuBarBadgeRenderConfig {
        let x = value(defaults, key: badgeRectXKey, fallback: defaultBadgeRect.origin.x, range: 0...20)
        let y = value(defaults, key: badgeRectYKey, fallback: defaultBadgeRect.origin.y, range: 0...20)
        let width = value(defaults, key: badgeRectWidthKey, fallback: defaultBadgeRect.width, range: 4...14)
        let height = value(defaults, key: badgeRectHeightKey, fallback: defaultBadgeRect.height, range: 4...14)
        let singleFont = value(defaults, key: singleDigitFontSizeKey, fallback: defaultSingleDigitFontSize, range: 6...14)
        let multiFont = value(defaults, key: multiDigitFontSizeKey, fallback: defaultMultiDigitFontSize, range: 6...14)
        let singleY = value(defaults, key: singleDigitYOffsetKey, fallback: defaultSingleDigitYOffset, range: -3...4)
        let multiY = value(defaults, key: multiDigitYOffsetKey, fallback: defaultMultiDigitYOffset, range: -3...4)
        let singleX = value(
            defaults,
            key: singleDigitXAdjustKey,
            legacyKey: legacySingleDigitXAdjustKey,
            fallback: defaultSingleDigitXAdjust,
            range: -4...4
        )
        let multiX = value(defaults, key: multiDigitXAdjustKey, fallback: defaultMultiDigitXAdjust, range: -4...4)
        let widthAdjust = value(defaults, key: textRectWidthAdjustKey, fallback: defaultTextRectWidthAdjust, range: -3...5)

        return MenuBarBadgeRenderConfig(
            badgeRect: NSRect(x: x, y: y, width: width, height: height),
            singleDigitFontSize: singleFont,
            multiDigitFontSize: multiFont,
            singleDigitYOffset: singleY,
            multiDigitYOffset: multiY,
            singleDigitXAdjust: singleX,
            multiDigitXAdjust: multiX,
            textRectWidthAdjust: widthAdjust
        )
    }

    static func copyPayload(defaults: UserDefaults = .standard) -> String {
        let config = badgeRenderConfig(defaults: defaults)
        let previewEnabled = defaults.bool(forKey: previewEnabledKey)
        let previewCount = max(0, min(defaults.integer(forKey: previewCountKey), 99))
        return """
        menubarDebugPreviewEnabled=\(previewEnabled)
        menubarDebugPreviewCount=\(previewCount)
        menubarDebugBadgeRectX=\(String(format: "%.2f", config.badgeRect.origin.x))
        menubarDebugBadgeRectY=\(String(format: "%.2f", config.badgeRect.origin.y))
        menubarDebugBadgeRectWidth=\(String(format: "%.2f", config.badgeRect.width))
        menubarDebugBadgeRectHeight=\(String(format: "%.2f", config.badgeRect.height))
        menubarDebugSingleDigitFontSize=\(String(format: "%.2f", config.singleDigitFontSize))
        menubarDebugMultiDigitFontSize=\(String(format: "%.2f", config.multiDigitFontSize))
        menubarDebugSingleDigitYOffset=\(String(format: "%.2f", config.singleDigitYOffset))
        menubarDebugMultiDigitYOffset=\(String(format: "%.2f", config.multiDigitYOffset))
        menubarDebugSingleDigitXAdjust=\(String(format: "%.2f", config.singleDigitXAdjust))
        menubarDebugMultiDigitXAdjust=\(String(format: "%.2f", config.multiDigitXAdjust))
        menubarDebugTextRectWidthAdjust=\(String(format: "%.2f", config.textRectWidthAdjust))
        """
    }

    private static func value(
        _ defaults: UserDefaults,
        key: String,
        legacyKey: String? = nil,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        if let parsed = parse(defaults.object(forKey: key), fallback: fallback, range: range) {
            return parsed
        }
        if let legacyKey, let parsed = parse(defaults.object(forKey: legacyKey), fallback: fallback, range: range) {
            return parsed
        }
        return fallback
    }

    private static func parse(
        _ object: Any?,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat? {
        guard let number = object as? NSNumber else {
            return nil
        }
        let candidate = CGFloat(number.doubleValue)
        guard candidate.isFinite else { return fallback }
        return max(range.lowerBound, min(candidate, range.upperBound))
    }
}

enum MenuBarIconRenderer {

    static func makeImage(unreadCount: Int) -> NSImage {
        let badgeText = MenuBarBadgeLabelFormatter.badgeText(for: unreadCount)
        let config = MenuBarIconDebugSettings.badgeRenderConfig()
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let glyphRect = NSRect(x: 1.2, y: 1.5, width: 11.6, height: 15.0)
        drawGlyph(in: glyphRect)

        if let text = badgeText {
            drawBadge(text: text, in: config.badgeRect, config: config)
        }

        image.isTemplate = true
        return image
    }

    private static func drawGlyph(in rect: NSRect) {
        // Match the canonical cmux center-mark path from Icon Center Image Artwork.svg.
        let srcMinX: CGFloat = 384.0
        let srcMinY: CGFloat = 255.0
        let srcWidth: CGFloat = 369.0
        let srcHeight: CGFloat = 513.0

        func map(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let nx = (x - srcMinX) / srcWidth
            let ny = (y - srcMinY) / srcHeight
            return NSPoint(
                x: rect.minX + nx * rect.width,
                y: rect.minY + (1.0 - ny) * rect.height
            )
        }

        let path = NSBezierPath()
        path.move(to: map(384.0, 255.0))
        path.line(to: map(753.0, 511.5))
        path.line(to: map(384.0, 768.0))
        path.line(to: map(384.0, 654.0))
        path.line(to: map(582.692, 511.5))
        path.line(to: map(384.0, 369.0))
        path.close()

        NSColor.black.setFill()
        path.fill()
    }

    private static func drawBadge(text: String, in rect: NSRect, config: MenuBarBadgeRenderConfig) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let fontSize: CGFloat = text.count > 1 ? config.multiDigitFontSize : config.singleDigitFontSize
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.systemBlue,
            .paragraphStyle: paragraph,
        ]
        let yOffset: CGFloat = text.count > 1 ? config.multiDigitYOffset : config.singleDigitYOffset
        let xAdjust: CGFloat = text.count > 1 ? config.multiDigitXAdjust : config.singleDigitXAdjust
        let textRect = NSRect(
            x: rect.origin.x + xAdjust,
            y: rect.origin.y + yOffset,
            width: rect.width + config.textRectWidthAdjust,
            height: rect.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attrs)
    }
}
