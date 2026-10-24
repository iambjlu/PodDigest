// app/Markdown.swift
// 小型 Markdown → HTML 轉換（標題、清單、表格、引用、程式碼、粗斜體、連結），給單檔 HTML／PDF／預覽用。
import Foundation

enum Markdown {
    struct Heading { let level: Int; let id: String; let text: String }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }
    private static func sub(_ r: NSRegularExpression, _ s: String, _ t: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    private static let reCode = re("`([^`]+)`")
    private static let reBold = re("\\*\\*(.+?)\\*\\*|__(.+?)__")
    private static let reItalic = re("(?<!\\*)\\*(?![\\s\\*])(.+?)(?<![\\s\\*])\\*(?!\\*)")
    private static let reStrike = re("~~(.+?)~~")
    private static let reLink = re("\\[([^\\]]+)\\]\\((https?://[^)\\s]+)\\)")
    private static let reAuto = re("(?<![\"'>=])(https?://[^\\s<>\"')）]+)")
    private static let reTime = re("[（(](\\d{1,2}:\\d{2}(?::\\d{2})?)[）)]")

    static func inline(_ raw: String) -> String {
        var codes: [String] = []
        var s = escape(raw)
        // 先把行內程式碼換成佔位符，避免裡面的 * _ 被當成格式
        let ns = s as NSString
        var out = "", last = 0
        for m in reCode.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += "\u{1}\(codes.count)\u{1}"
            codes.append("<code>\(ns.substring(with: m.range(at: 1)))</code>")
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        s = out
        s = sub(reLink, s, "<a href=\"$2\">$1</a>")
        s = sub(reAuto, s, "<a href=\"$1\">$1</a>")
        s = sub(reBold, s, "<strong>$1$2</strong>")
        s = sub(reItalic, s, "<em>$1</em>")
        s = sub(reStrike, s, "<del>$1</del>")
        s = sub(reTime, s, "<span class=\"ts\">（$1）</span>")
        for (i, c) in codes.enumerated() { s = s.replacingOccurrences(of: "\u{1}\(i)\u{1}", with: c) }
        return s
    }

    static func slug(_ s: String, used: inout Set<String>) -> String {
        var base = s.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "section" }
        var id = base, n = 2
        while used.contains(id) { id = "\(base)-\(n)"; n += 1 }
        used.insert(id)
        return id
    }

    // 清單項目
    private struct Item { var indent: Int; var ordered: Bool; var text: String; var children: [Item] = [] }
    private static let reListLine = re("^(\\s*)([-*+]|\\d+[.)])\\s+(.*)$")
    private static let reHeading = re("^(#{1,6})\\s+(.*?)\\s*#*\\s*$")
    private static let reHR = re("^\\s*([-*_])(\\s*\\1){2,}\\s*$")
    private static let reTableSep = re("^\\s*\\|?\\s*:?-{2,}:?\\s*(\\|\\s*:?-{2,}:?\\s*)*\\|?\\s*$")

    private static func isSpecial(_ line: String) -> Bool {
        let r = NSRange(line.startIndex..., in: line)
        return line.hasPrefix("```") || line.hasPrefix(">") || reHeading.firstMatch(in: line, range: r) != nil
            || reListLine.firstMatch(in: line, range: r) != nil || reHR.firstMatch(in: line, range: r) != nil
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func renderList(_ items: [Item]) -> String {
        guard let first = items.first else { return "" }
        if let k = items.firstIndex(where: { $0.ordered != first.ordered }) {     // 有序／無序清單相鄰時分開渲染
            return renderList(Array(items[..<k])) + renderList(Array(items[k...]))
        }
        let tag = first.ordered ? "ol" : "ul"
        var html = "<\(tag)>"
        for it in items {
            var text = it.text
            var cls = ""
            if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4); cls = " class=\"task\"" }
            else if text.lowercased().hasPrefix("[x] ") { text = "☑ " + text.dropFirst(4); cls = " class=\"task done\"" }
            html += "<li\(cls)>" + inline(text) + renderList(it.children) + "</li>"
        }
        return html + "</\(tag)>"
    }

    static func render(_ md: String) -> (html: String, headings: [Heading]) {
        var headings: [Heading] = []
        var used = Set<String>()
        let html = blocks(md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"), headings: &headings, used: &used)
        return (html, headings)
    }

    private static func blocks(_ lines: [String], headings: inout [Heading], used: inout Set<String>) -> String {
        var html = ""
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let r = NSRange(line.startIndex..., in: line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            if trimmed.hasPrefix("```") {                                   // 程式碼區塊
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                i += 1
                html += "<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>\n"
                continue
            }
            if let m = reHeading.firstMatch(in: line, range: r) {          // 標題
                let ns = line as NSString
                let level = ns.substring(with: m.range(at: 1)).count
                let text = ns.substring(with: m.range(at: 2))
                let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                let id = slug(plain, used: &used)
                headings.append(Heading(level: level, id: id, text: plain))
                html += "<h\(level) id=\"\(id)\">\(inline(text))</h\(level)>\n"
                i += 1
                continue
            }
            if reHR.firstMatch(in: line, range: r) != nil { html += "<hr>\n"; i += 1; continue }
            if trimmed.hasPrefix(">") {                                     // 引用
                var inner: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var t = lines[i].trimmingCharacters(in: .whitespaces)
                    t.removeFirst()
                    if t.hasPrefix(" ") { t.removeFirst() }
                    inner.append(t); i += 1
                }
                var dummyH: [Heading] = []
                html += "<blockquote>" + blocks(inner, headings: &dummyH, used: &used) + "</blockquote>\n"
                continue
            }
            if line.contains("|"), i + 1 < lines.count,
               reTableSep.firstMatch(in: lines[i + 1], range: NSRange(lines[i + 1].startIndex..., in: lines[i + 1])) != nil {
                let head = cells(line)                                      // 表格
                let aligns = cells(lines[i + 1]).map { c -> String in
                    c.hasPrefix(":") && c.hasSuffix(":") ? "center" : c.hasSuffix(":") ? "right" : "left" }
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i])); i += 1
                }
                func td(_ tag: String, _ row: [String]) -> String {
                    "<tr>" + row.enumerated().map { "<\(tag) style=\"text-align:\($0.offset < aligns.count ? aligns[$0.offset] : "left")\">\(inline($0.element))</\(tag)>" }.joined() + "</tr>"
                }
                html += "<div class=\"tbl\"><table><thead>" + td("th", head) + "</thead><tbody>" + rows.map { td("td", $0) }.joined() + "</tbody></table></div>\n"
                continue
            }
            if reListLine.firstMatch(in: line, range: r) != nil {           // 清單（支援縮排巢狀）
                var flat: [Item] = []
                while i < lines.count {
                    let l = lines[i]
                    let lr = NSRange(l.startIndex..., in: l)
                    if let m = reListLine.firstMatch(in: l, range: lr) {
                        let ns = l as NSString
                        let marker = ns.substring(with: m.range(at: 2))
                        let ind = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "\t", with: "    ").count
                        flat.append(Item(indent: ind, ordered: marker.first!.isNumber, text: ns.substring(with: m.range(at: 3))))
                        i += 1
                    } else if !l.trimmingCharacters(in: .whitespaces).isEmpty, l.hasPrefix(" "), !flat.isEmpty, !isSpecial(l) {
                        flat[flat.count - 1].text += " " + l.trimmingCharacters(in: .whitespaces)   // 續行
                        i += 1
                    } else if l.trimmingCharacters(in: .whitespaces).isEmpty, i + 1 < lines.count,
                              reListLine.firstMatch(in: lines[i + 1], range: NSRange(lines[i + 1].startIndex..., in: lines[i + 1])) != nil {
                        i += 1                                              // 清單項目之間的空行
                    } else { break }
                }
                html += renderList(nest(flat)) + "\n"
                continue
            }
            var para: [String] = [trimmed]                                  // 段落
            i += 1
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !isSpecial(lines[i]) {
                para.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1
            }
            html += "<p>" + para.map(inline).joined(separator: "<br>") + "</p>\n"
        }
        return html
    }

    private static func nest(_ flat: [Item]) -> [Item] {
        var root: [Item] = []
        var stack: [(indent: Int, path: [Int])] = []
        for it in flat {
            while let l = stack.last, l.indent >= it.indent { stack.removeLast() }
            if let parent = stack.last {
                var path = parent.path
                append(&root, path: path, item: it)
                path.append(childCount(root, path: parent.path) - 1)
                stack.append((it.indent, path))
            } else {
                root.append(it)
                stack.append((it.indent, [root.count - 1]))
            }
        }
        return root
    }
    private static func append(_ items: inout [Item], path: [Int], item: Item) {
        guard let f = path.first else { return }
        if path.count == 1 { items[f].children.append(item) }
        else { append(&items[f].children, path: Array(path.dropFirst()), item: item) }
    }
    private static func childCount(_ items: [Item], path: [Int]) -> Int {
        guard let f = path.first else { return items.count }
        return childCount(items[f].children, path: Array(path.dropFirst()))
    }
}
