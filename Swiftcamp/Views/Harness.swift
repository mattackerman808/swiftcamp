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
                // macOS grants activation when it feels like it: the
                // same launch got it one run and not the next. The
                // popover a search puts up needs a key window, so keep
                // asking for a couple of seconds and say what happened,
                // because a run without the popover otherwise reads as
                // the search being broken.
                activate(window)
                return window.makeFirstResponder(field)
            }
        }
        // Say what was there instead, since a field that is not found
        // after a search has run is a different bug from one never built.
        let items = NSApp.windows.filter(\.isVisible).map { window in
            "\(Swift.type(of: window)): " + (window.toolbar?.items.map { "\(Swift.type(of: $0))" }.joined(separator: ",") ?? "no toolbar")
        }
        NSLog("[Swiftcamp] harness: no search field in any window; %@", items.joined(separator: "; "))
        return false
    }

    /// Waits for it, too. Keystrokes typed into a field before its
    /// window is key go into the text and nowhere else: the suggestion
    /// popover arms when the field takes focus in a key window, so typing
    /// a beat too early left every later picture without it.
    private static func activate(_ window: NSWindow) {
        let deadline = Date(timeIntervalSinceNow: 3)
        var attempts = 0
        while Date() < deadline {
            attempts += 1
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if NSApp.isActive, window.isKeyWindow {
                NSLog("[Swiftcamp] harness: active after %d attempts", attempts)
                return
            }
            // Activation arrives as an application event, which only the
            // application's own loop dispatches: spinning the run loop
            // here waited three seconds and never saw it.
            while let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.1),
                                              inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        NSLog("[Swiftcamp] harness: never became the active app; no popover will show")
    }

    private static func searchField(in window: NSWindow) -> NSTextField? {
        if let item = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
            return item.searchField
        }
        var queue: [NSView] = [window.contentView?.superview ?? window.contentView].compactMap { $0 }
        var fallback: NSTextField?
        while let view = queue.first {
            queue.removeFirst()
            if let field = view as? NSSearchField { return field }
            // SwiftUI can host the field as a plain text field once a
            // search has run; the prompt is what tells it apart.
            if let field = view as? NSTextField, field.placeholderString?.contains("coordinates") == true {
                fallback = fallback ?? field
            }
            queue.append(contentsOf: view.subviews)
        }
        return fallback
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
