#if os(macOS)
import AppKit

/// Eyes and hands on the real window, for `-SwiftcampScript`.
///
/// The map harness dispatches DOM events on the canvas, which covers
/// everything drawn by MapLibre and nothing drawn by AppKit: the search
/// field, its suggestions, the sidebar, a sheet. Those need real key
/// events through the real first responder, and a picture afterwards.
/// Both are possible without Accessibility permission because the events
/// are posted into this process's own queue and the pictures are this
/// process's own views asked to draw themselves, popovers included, since
/// a popover is a window of ours too.
enum Harness {
    /// Puts the toolbar's search field first responder.
    static func focusSearchField() -> Bool {
        for window in NSApp.windows where window.isVisible {
            if let field = searchField(in: window) {
                // A process launched from a terminal is not the active
                // app, and an inactive app has no key window, so events
                // posted to the application go nowhere.
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                return window.makeFirstResponder(field)
            }
        }
        NSLog("[Swiftcamp] harness: no search field in any window")
        return false
    }

    private static func searchField(in window: NSWindow) -> NSSearchField? {
        if let item = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
            return item.searchField
        }
        var queue: [NSView] = [window.contentView?.superview ?? window.contentView].compactMap { $0 }
        while let view = queue.first {
            queue.removeFirst()
            if let field = view as? NSSearchField { return field }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Types text as key events, one character at a time, to whatever is
    /// first responder. A newline is Return.
    static func type(_ text: String) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        for character in text {
            let string = String(character)
            let keyCode: UInt16 = character == "\n" ? 36 : 0
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                characters: string, charactersIgnoringModifiers: string,
                                                isARepeat: false, keyCode: keyCode) {
                    // Straight to the window rather than the application
                    // queue, whose key-window routing an inactive app fails.
                    window.sendEvent(event)
                }
            }
        }
    }

    /// Writes a PNG of every visible window, `<prefix>-<n>-<class>.png`,
    /// including the popover a search puts up. The frame view rather than
    /// the content view, so the toolbar is in the picture.
    static func snapshotWindows(to prefix: String) {
        for (index, window) in NSApp.windows.filter({ $0.isVisible }).enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = String(describing: Swift.type(of: window)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            let path = "\(prefix)-\(index)-\(name).png"
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                NSLog("[Swiftcamp] harness: window %d %@ %@ -> %@", index, name,
                      NSStringFromRect(window.frame), path)
            }
        }
    }
}
#endif
