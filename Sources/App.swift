import AppKit
import UniformTypeIdentifiers

@main
@MainActor
enum GalleyMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controllers: [DocumentWindowController] = []
    private let recentMenu = NSMenu(title: "Open Recent")

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MenuBuilder.build(appDelegate: self, recentMenu: recentMenu)
        MenuBuilder.updateColorChecks(0)
        recentMenu.delegate = self
        if let view = NSApp.mainMenu?.item(withTitle: "View")?.submenu {
            view.delegate = self
            view.autoenablesItems = false     // enabled states are set in updateZoomItems
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Support `Galley.app/Contents/MacOS/Galley file.pdf` from the terminal.
        for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
            let url = URL(fileURLWithPath: arg)
            if url.pathExtension.lowercased() == "pdf", FileManager.default.fileExists(atPath: url.path) {
                open(url)
            }
        }
        NSApp.activate()
        perform(#selector(showOpenPanelIfIdle), with: nil, afterDelay: 0.6)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in controllers where !controller.isClosed { controller.saveAnnotationsNow() }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && controllers.isEmpty { openFileAction(nil) }
        return true
    }

    // MARK: Opening files

    @objc private func showOpenPanelIfIdle() {
        if controllers.isEmpty { openFileAction(nil) }
    }

    @objc func openFileAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    func open(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = controllers.first(where: { $0.url == resolved }) {
            existing.showWindow(nil)
            return
        }
        guard let controller = DocumentWindowController(url: resolved) else {
            let alert = NSAlert()
            alert.messageText = "Couldn’t open “\(resolved.lastPathComponent)”"
            alert.informativeText = "The file isn’t a readable PDF, or it is still being written."
            alert.runModal()
            return
        }
        controllers.append(controller)
        controller.showWindow(nil)
        NSDocumentController.shared.noteNewRecentDocumentURL(resolved)
    }

    func controllerDidClose(_ controller: DocumentWindowController) {
        // Defer the release so the controller isn't freed inside its own delegate callback.
        perform(#selector(pruneClosedControllers), with: nil, afterDelay: 0)
    }

    @objc private func pruneClosedControllers() {
        controllers.removeAll { $0.isClosed }
    }

    // MARK: Open Recent

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "View" {
            updateZoomItems(in: menu)
            for item in menu.items where item.action == #selector(pageThemeAction(_:)) {
                item.state = item.representedObject as? String == PageTheme.current.rawValue ? .on : .off
            }
            return
        }
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(NSMenuItem.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentsAction(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    /// Checkmark on the active zoom mode, and the Reading Size adjustment in its title.
    private func updateZoomItems(in menu: NSMenu) {
        let controller = (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? DocumentWindowController
        let modes: [(tag: Int, mode: ZoomMode)] = [(101, .fitPage), (102, .fitWidth), (107, .fitText), (103, .readingSize), (104, .actualSize)]
        for entry in modes {
            menu.item(withTag: entry.tag)?.state = controller?.currentZoomMode == entry.mode ? .on : .off
        }
        menu.item(withTag: 108)?.state = controller?.model.sidebarMode == .outline ? .on : .off
        menu.item(withTag: 109)?.state = controller?.model.sidebarMode == .thumbnails ? .on : .off
        let inReadingSize = controller?.currentZoomMode == .readingSize
        menu.item(withTag: 105)?.isEnabled = inReadingSize
        menu.item(withTag: 106)?.isEnabled = inReadingSize
        if let item = menu.item(withTag: 103) {
            let notes = [controller?.readingAdjustmentText() == nil ? nil : "Adjusted",
                         controller?.isReadingSizeCapped == true && controller?.currentZoomMode == .readingSize ? "Capped" : nil]
                .compactMap { $0 }
            item.title = notes.isEmpty ? "Reading Size" : "Reading Size (\(notes.joined(separator: ", ")))"
        }
    }

    @objc private func openRecentAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open(url)
    }

    @objc func showShortcutsAction(_ sender: Any?) { ShortcutsPanel.shared.toggle() }

    @objc func pageThemeAction(_ sender: NSMenuItem) {
        guard let theme = (sender.representedObject as? String).flatMap(PageTheme.init) else { return }
        PageTheme.current = theme
    }

    @objc private func clearRecentsAction(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}

@MainActor
enum MenuBuilder {
    static func build(appDelegate: AppDelegate, recentMenu: NSMenu) -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }

        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            menu.addItem(item)
        }

        let app = submenu("Galley")
        add(app, "About Galley", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", [])
        app.addItem(NSMenuItem.separator())
        add(app, "Hide Galley", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "", [])
        app.addItem(NSMenuItem.separator())
        add(app, "Quit Galley", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "Open…", #selector(AppDelegate.openFileAction(_:)), "o", target: appDelegate)
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        file.addItem(recentItem)
        file.addItem(NSMenuItem.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(file, "Export Without Annotations…", #selector(DocumentWindowController.exportCleanAction(_:)), "", [])
        add(file, "Revert to Original…", #selector(DocumentWindowController.revertToOriginalAction(_:)), "", [])
        add(file, "Show in Finder", #selector(DocumentWindowController.revealInFinderAction(_:)), "r", [.command, .option])

        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(NSMenuItem.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(NSMenuItem.separator())
        add(edit, "Highlight", #selector(DocumentWindowController.highlightSelectionAction(_:)), "h", [.command, .control])
        add(edit, "Underline", #selector(DocumentWindowController.underlineSelectionAction(_:)), "u", [.command, .control])
        let colorItem = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        let colors = NSMenu(title: "Colour")
        for (index, entry) in Annotations.colors.enumerated() {
            // (Keys 1–8 aren't shown here: a menu shortcut without ⌘ would fire while typing.)
            let item = NSMenuItem(title: "\(entry.name) (\(index + 1))", action: #selector(DocumentWindowController.colorMenuAction(_:)),
                                  keyEquivalent: "")
            item.tag = index
            item.image = swatch(entry.color)
            colors.addItem(item)
        }
        colorItem.submenu = colors
        edit.addItem(colorItem)
        add(edit, "Add Comment…", #selector(DocumentWindowController.commentAction(_:)), "", [])
        add(edit, "Remove All Annotations…", #selector(DocumentWindowController.removeAllAnnotationsAction(_:)), "", [])
        edit.addItem(NSMenuItem.separator())
        // Saved into the file like highlights, so here rather than in View.
        add(edit, "Rotate Left", #selector(DocumentWindowController.rotateLeftAction(_:)), "", [])
        add(edit, "Rotate Right", #selector(DocumentWindowController.rotateRightAction(_:)), "", [])
        edit.addItem(NSMenuItem.separator())
        add(edit, "Find…", #selector(DocumentWindowController.focusSearch(_:)), "f")
        add(edit, "Find Next", #selector(DocumentWindowController.findNextMatch(_:)), "g")
        add(edit, "Find Previous", #selector(DocumentWindowController.findPreviousMatch(_:)), "g", [.command, .shift])

        let view = submenu("View")
        add(view, "Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "b")
        add(view, "Table of Contents", #selector(DocumentWindowController.showOutlineAction(_:)), "", [])
        view.items.last?.tag = 108
        add(view, "Page Thumbnails", #selector(DocumentWindowController.showThumbnailsAction(_:)), "", [])
        view.items.last?.tag = 109
        view.addItem(NSMenuItem.separator())
        add(view, "Fit Page", #selector(DocumentWindowController.fitPageAction(_:)), "", [])
        view.items.last?.tag = 101
        add(view, "Fit Width", #selector(DocumentWindowController.fitWidthAction(_:)), "", [])
        view.items.last?.tag = 102
        add(view, "Fit Text Width", #selector(DocumentWindowController.fitTextAction(_:)), "", [])
        view.items.last?.tag = 107
        add(view, "Reading Size", #selector(DocumentWindowController.readingSizeAction(_:)), "", [])
        view.items.last?.tag = 103
        add(view, "Actual Size", #selector(DocumentWindowController.actualSizeAction(_:)), "", [])
        view.items.last?.tag = 104
        add(view, "Switch Zoom Mode", #selector(DocumentWindowController.switchZoomModeAction(_:)), "0")
        view.addItem(NSMenuItem.separator())
        add(view, "Zoom In", #selector(DocumentWindowController.zoomInAction(_:)), "+")
        add(view, "Zoom Out", #selector(DocumentWindowController.zoomOutAction(_:)), "-")
        add(view, "Increase Reading Size", #selector(DocumentWindowController.increaseReadingSizeAction(_:)), "+", [.command, .option])
        view.items.last?.tag = 105
        add(view, "Decrease Reading Size", #selector(DocumentWindowController.decreaseReadingSizeAction(_:)), "-", [.command, .option])
        view.items.last?.tag = 106
        add(view, "Reset Reading Size", #selector(DocumentWindowController.resetReadingSizeAction(_:)), "", [])
        view.addItem(NSMenuItem.separator())
        // Page colours, laid out like the zoom modes (checkmark on the current one, ⌘9 below as ⌘0).
        for theme in PageTheme.allCases {
            // (D isn't shown here: a menu shortcut without ⌘ would fire while typing.)
            let item = NSMenuItem(title: theme.title, action: #selector(AppDelegate.pageThemeAction(_:)), keyEquivalent: "")
            item.target = appDelegate
            item.representedObject = theme.rawValue
            view.addItem(item)
        }
        add(view, "Switch Page Colour", #selector(DocumentWindowController.switchPageThemeAction(_:)), "9")
        view.addItem(NSMenuItem.separator())
        add(view, "Toggle Two-Page Layout", #selector(DocumentWindowController.toggleTwoPagesAction(_:)), "2", [.command, .option])
        add(view, "Toggle Split View", #selector(DocumentWindowController.toggleSplitViewAction(_:)), "s", [.command, .option])
        add(view, "Switch Split Orientation", #selector(DocumentWindowController.toggleSplitOrientationAction(_:)), "", [])
        view.addItem(NSMenuItem.separator())
        add(view, "Slide Show", #selector(DocumentWindowController.toggleSlideShowAction(_:)), "f", [.command, .shift])

        let go = submenu("Go")
        add(go, "Previous Page", #selector(DocumentWindowController.previousPageAction(_:)), functionKey(NSUpArrowFunctionKey), [.command, .option])
        add(go, "Next Page", #selector(DocumentWindowController.nextPageAction(_:)), functionKey(NSDownArrowFunctionKey), [.command, .option])
        add(go, "First Page", #selector(DocumentWindowController.firstPageAction(_:)), "", [])
        add(go, "Last Page", #selector(DocumentWindowController.lastPageAction(_:)), "", [])
        go.addItem(NSMenuItem.separator())
        add(go, "Back", #selector(DocumentWindowController.historyBackAction(_:)), functionKey(NSLeftArrowFunctionKey), [.command, .option])
        add(go, "Forward", #selector(DocumentWindowController.historyForwardAction(_:)), functionKey(NSRightArrowFunctionKey), [.command, .option])
        go.addItem(NSMenuItem.separator())
        add(go, "Go to…", #selector(DocumentWindowController.goToPageAction(_:)), "g", [.command, .option])

        let window = submenu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)), "", [])
        window.addItem(NSMenuItem.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", [])
        NSApp.windowsMenu = window

        let help = submenu("Help")
        // (? isn't a key equivalent here: without ⌘ it would fire while typing.)
        add(help, "Keyboard Shortcuts (?)", #selector(AppDelegate.showShortcutsAction(_:)), "", [])
        NSApp.helpMenu = help

        return main
    }

    /// A small round swatch for the Colour menu.
    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }

    /// The checkmark on the colour M and U use in the front window.
    static func updateColorChecks(_ current: Int) {
        guard let menu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.item(withTitle: "Colour")?.submenu else { return }
        for item in menu.items { item.state = item.tag == current ? .on : .off }
    }

    private static func functionKey(_ key: Int) -> String {
        String(utf16CodeUnits: [unichar(key)], count: 1)
    }
}
