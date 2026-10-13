import SwiftUI

/// Renders ntfy markdown bodies into an AttributedString for the history list.
/// Line level: headings, unordered/ordered lists, blockquotes, fenced code,
/// horizontal rules. Inline: bold, italic, strikethrough, code spans and links.
/// Notification banners keep using MarkdownStripper; this is display-only.
///
/// Pieces must set attributes via the typed properties (`a.font = …`): values
/// written through `AttributeContainer` dictionary literals silently fail to
/// register on the SwiftUI-scoped keys and read back as nil.
enum MarkdownRenderer {
    static func baseFont(size: CGFloat = 13) -> Font { .system(size: size) }
    static func codeFont(size: CGFloat = 13) -> Font { .system(size: max(10, size - 1), design: .monospaced) }

    static func render(_ source: String, fontSize: CGFloat = 13) -> AttributedString {
        let baseFont = baseFont(size: fontSize)
        var out = AttributedString()
        var inCodeBlock = false

        func addLineBreak() {
            if !out.characters.isEmpty {
                out.append(makePiece("\n", font: baseFont))
            }
        }

        for rawLine in source.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock {
                addLineBreak()
                out.append(makePiece(rawLine, font: codeFont(size: fontSize)))
                continue
            }

            if trimmed.isEmpty {
                addLineBreak()
                continue
            }
            if isHorizontalRule(trimmed) {
                addLineBreak()
                out.append(makePiece("───────", font: baseFont, color: .secondary))
                continue
            }
            if let (level, content) = heading(trimmed) {
                addLineBreak()
                let size = fontSize + headingDelta(level)
                let font = Font.system(size: size, weight: .bold)
                out.append(renderInline(content, baseFont: font, baseColor: .primary, codeFont: codeFont(size: size)))
                continue
            }
            if let content = blockquoteContent(trimmed) {
                addLineBreak()
                var line = renderInline(content, baseFont: baseFont, baseColor: .secondary, codeFont: codeFont(size: fontSize))
                line.insert(makePiece("▏", font: baseFont, color: .secondary), at: line.startIndex)
                out.append(line)
                continue
            }
            if let (marker, content) = listItem(trimmed) {
                addLineBreak()
                var line = renderInline(content, baseFont: baseFont, baseColor: .primary, codeFont: codeFont(size: fontSize))
                line.insert(makePiece("\(marker) ", font: baseFont), at: line.startIndex)
                out.append(line)
                continue
            }

            addLineBreak()
            out.append(renderInline(trimmed, baseFont: baseFont, baseColor: .primary, codeFont: codeFont(size: fontSize)))
        }

        return out
    }

    // MARK: - Line classification

    /// Heading size offsets from the body size, so the whole document scales together.
    private static func headingDelta(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 4
        case 2: return 2.5
        case 3: return 1
        default: return 0
        }
    }

    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#", level < 6 {
            rest = rest.dropFirst()
            level += 1
        }
        guard level > 0, rest.first == " " else { return nil }
        return (level, String(rest.dropFirst()))
    }

    private static func blockquoteContent(_ line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        return String(line.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (marker: String, content: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return ("•", String(line.dropFirst(2)))
        }
        // Ordered: "12. text"
        var digits = ""
        for ch in line {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        let after = line.dropFirst(digits.count)
        if !digits.isEmpty, after.hasPrefix(". "), let n = Int(digits) {
            return ("\(n).", String(after.dropFirst(2)))
        }
        return nil
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let chars = Set(line)
        return line.count >= 3 && (chars == ["-"] || chars == ["*"] || chars == ["_"])
    }

    // MARK: - Inline parsing

    private static let inlinePattern = try! NSRegularExpression(
        pattern: "!\\[([^\\]]*)\\]\\([^)]*\\)|\\[([^\\]]+)\\]\\(([^)\\s]+)[^)]*\\)|\\*\\*([^*\\n]+)\\*\\*|__([^_\\n]+)__|`([^`\\n]+)`|~~([^~\\n]+)~~|\\*([^*\\n]+)\\*|_([^_\\n]+)_"
    )

    private static func makePiece(_ text: String, font: Font, color: Color? = nil) -> AttributedString {
        var a = AttributedString(text)
        a.font = font
        if let color { a.foregroundColor = color }
        return a
    }

    static func renderInline(_ text: String, baseFont: Font, baseColor: Color, codeFont: Font) -> AttributedString {
        var out = AttributedString()
        let ns = text as NSString
        var cursor = 0

        func appendPlain(_ range: NSRange) {
            guard range.length > 0 else { return }
            out.append(makePiece(ns.substring(with: range), font: baseFont, color: baseColor))
        }

        let matches = inlinePattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            appendPlain(NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length

            func group(_ i: Int) -> String? {
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }

            if let alt = group(1) {
                // Image: show the alt text with a marker; URLs in ntfy bodies are usually transient.
                out.append(makePiece("🖼 " + (alt.isEmpty ? "图片" : alt), font: baseFont, color: .secondary))
            } else if let label = group(2), let url = group(3) {
                if let target = URL(string: url) {
                    var piece = makePiece(label, font: baseFont)
                    piece.link = target
                    out.append(piece)
                } else {
                    // Malformed URL: fall back to plain colored text.
                    out.append(makePiece("\(label) (\(url))", font: baseFont, color: baseColor))
                }
            } else if let bold = group(4) ?? group(5) {
                var piece = makePiece(bold, font: baseFont.bold(), color: baseColor)
                piece.inlinePresentationIntent = .stronglyEmphasized
                out.append(piece)
            } else if let code = group(6) {
                var piece = makePiece(code, font: codeFont, color: baseColor)
                piece.backgroundColor = Color.primary.opacity(0.08)
                out.append(piece)
            } else if let strike = group(7) {
                var piece = makePiece(strike, font: baseFont, color: baseColor)
                piece.strikethroughStyle = .single
                out.append(piece)
            } else if let italic = group(8) ?? group(9) {
                var piece = makePiece(italic, font: baseFont.italic(), color: baseColor)
                piece.inlinePresentationIntent = .emphasized
                out.append(piece)
            }
        }
        appendPlain(NSRange(location: cursor, length: ns.length - cursor))
        return out
    }
}
