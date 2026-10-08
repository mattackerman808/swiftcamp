#if os(macOS)
import AppKit
import WebKit

/// File, Print: the map as it stands on screen, and under it what the
/// selection says, BaseCamp's printout of a route beside its directions.
///
/// One text view holding the picture and the words, printed as it
/// paginates. A text view breaks a long list of turns across pages
/// itself, which a hand-laid page would have to reimplement, and the
/// map is a picture inside it rather than the web view printing itself:
/// WebKit prints a page's DOM and a WebGL canvas comes out blank, where a
/// snapshot of the view is exactly the frame on screen.
@MainActor
enum MapPrinting {
    /// What goes under the map: a heading and its lines.
    struct Section {
        var heading: String
        var lines: [String]
    }

    /// The web view the map is in, for its picture. Weak, and set by the
    /// host when it makes the view; there is one map window.
    static weak var mapView: WKWebView?

    /// The map as drawn, or nil without a map window.
    static func snapshot() async -> NSImage? {
        guard let view = mapView else { return nil }
        return await withCheckedContinuation { continuation in
            view.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
        }
    }

    /// The printout: a title, a line under it, the map scaled to the page,
    /// the attribution the data's licence asks for, then each section.
    static func document(title: String, subtitle: String?, map: NSImage?, attribution: String,
                         sections: [Section], width: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ text: String, _ font: NSFont, color: NSColor = .black, after: CGFloat = 4) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = after
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]))
        }
        add(title, .boldSystemFont(ofSize: 17), after: 2)
        if let subtitle { add(subtitle, .systemFont(ofSize: 10), color: .darkGray, after: 8) }
        if let map {
            let scale = min(1, width / max(map.size.width, 1))
            let attachment = NSTextAttachment()
            attachment.image = map
            attachment.bounds = CGRect(x: 0, y: 0, width: map.size.width * scale, height: map.size.height * scale)
            out.append(NSAttributedString(attachment: attachment))
            out.append(NSAttributedString(string: "\n"))
        }
        add(attribution, .systemFont(ofSize: 8), color: .gray, after: 12)
        for section in sections {
            add(section.heading, .boldSystemFont(ofSize: 12), after: 4)
            for line in section.lines { add(line, .systemFont(ofSize: 10), after: 2) }
            add("", .systemFont(ofSize: 6))
        }
        return out
    }

    /// Prints a document: the print panel, or with `url` straight to a
    /// PDF, which is how a script checks what would come out.
    static func print(_ document: NSAttributedString, to url: URL? = nil) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        if let url {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        }
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(document)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = url == nil
        operation.showsProgressPanel = url == nil
        operation.jobTitle = document.string.components(separatedBy: "\n").first ?? "Swiftcamp"
        operation.run()
    }

    /// The width the document is laid out for, the page less its margins.
    static var printableWidth: CGFloat {
        let info = NSPrintInfo.shared
        return info.paperSize.width - 72
    }
}
#endif
