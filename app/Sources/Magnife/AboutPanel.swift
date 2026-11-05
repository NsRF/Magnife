import AppKit

/// Magnife > About Magnife: the standard About panel, with the author's links
/// as its credits (docs/ux.md, Menu bar). The links open in the default browser.
enum AboutPanel {
    static let author = "Nasser Farhat"
    static let links: [(title: String, url: URL)] = [
        ("GitHub", URL(string: "https://github.com/NsRF")!),
        ("LinkedIn", URL(string: "https://www.linkedin.com/in/nasserfarhat/")!),
    ]

    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    /// "Made by Nasser Farhat", then "GitHub · LinkedIn" as links, centered.
    static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(string: "Made by \(author)\n", attributes: plain)
        for (index, link) in links.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "  ·  ", attributes: plain)) }
            var attributes = plain
            attributes[.link] = link.url
            attributes[.toolTip] = link.url.absoluteString
            text.append(NSAttributedString(string: link.title, attributes: attributes))
        }
        return text
    }
}
