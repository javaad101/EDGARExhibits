import Foundation

/// Output of scanning an HTML document for `<base href>` and `<a href>` links in a single UTF-8 pass.
struct ScannedHTMLDocument: Sendable {
    struct RawLink: Sendable, Equatable {
        let href: String
        let text: String
    }

    let baseHref: String?
    let links: [RawLink]
}

/// Zero-DOM, single-pass byte scanner for extracting `<base href>` and `<a href>` links from large EDGAR HTML filings.
enum HTMLLinkScanner {
    static func scan(_ data: Data) -> ScannedHTMLDocument {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return scan(bytes)
        }
    }

    private static func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> ScannedHTMLDocument {
        let count = bytes.count
        var baseHref: String?
        var links: [ScannedHTMLDocument.RawLink] = []
        links.reserveCapacity(32)

        var i = 0
        while i < count {
            // Scan forward to next '<'
            while i < count, bytes[i] != 0x3C { i += 1 }
            guard i + 1 < count else { break }

            // 1. Skip HTML comments: <!-- ... -->
            if i + 3 < count,
               bytes[i + 1] == 0x21, bytes[i + 2] == 0x2D, bytes[i + 3] == 0x2D {
                i += 4
                var closed = false
                while i + 2 < count {
                    if bytes[i] == 0x2D, bytes[i + 1] == 0x2D, bytes[i + 2] == 0x3E {
                        i += 3
                        closed = true
                        break
                    }
                    i += 1
                }
                if !closed { break }
                continue
            }

            // 2. Skip <script ...>...</script> and <style ...>...</style>
            if matchesTag(bytes, at: i + 1, asciiLowercase: [0x73, 0x63, 0x72, 0x69, 0x70, 0x74]) { // "script"
                i += 7
                skipToTagEnd(bytes, index: &i)
                skipUntilClosingTag(bytes, index: &i, asciiLowercase: [0x73, 0x63, 0x72, 0x69, 0x70, 0x74])
                continue
            }
            if matchesTag(bytes, at: i + 1, asciiLowercase: [0x73, 0x74, 0x79, 0x6C, 0x65]) { // "style"
                i += 6
                skipToTagEnd(bytes, index: &i)
                skipUntilClosingTag(bytes, index: &i, asciiLowercase: [0x73, 0x74, 0x79, 0x6C, 0x65])
                continue
            }

            // 3. First <base ... href="...">
            if baseHref == nil,
               matchesTag(bytes, at: i + 1, asciiLowercase: [0x62, 0x61, 0x73, 0x65]) { // "base"
                i += 5
                let (href, _) = parseOpenTagAttributes(bytes, index: &i)
                if let href, !href.isEmpty {
                    baseHref = href
                }
                continue
            }

            // 4. <a ... href="...">anchor text</a>
            if matchesTag(bytes, at: i + 1, asciiLowercase: [0x61]) { // "a"
                i += 2
                let (href, selfClosing) = parseOpenTagAttributes(bytes, index: &i)
                if let href, !href.isEmpty {
                    let text = selfClosing ? "" : collectAnchorText(bytes, index: &i)
                    links.append(.init(href: href, text: text))
                }
                continue
            }

            i += 1
        }

        return ScannedHTMLDocument(baseHref: baseHref, links: links)
    }

    /// Parses attributes of `<base ...>` or `<a ...>` up to `>`, allocating a `String` only for `href`.
    private static func parseOpenTagAttributes(
        _ bytes: UnsafeBufferPointer<UInt8>,
        index i: inout Int
    ) -> (href: String?, selfClosing: Bool) {
        let count = bytes.count
        var href: String?
        var lastSlash = false

        while i < count {
            let b = bytes[i]
            if isSpace(b) {
                i += 1
                continue
            }
            if b == 0x3E /* > */ {
                i += 1
                return (href, lastSlash)
            }
            if b == 0x2F /* / */ {
                lastSlash = true
                i += 1
                continue
            }
            lastSlash = false

            let nameStart = i
            while i < count, isAttrNameChar(bytes[i]) {
                i += 1
            }
            let nameLen = i - nameStart
            let isHref = (nameLen == 4)
                && lower(bytes[nameStart]) == 0x68     // 'h'
                && lower(bytes[nameStart + 1]) == 0x72 // 'r'
                && lower(bytes[nameStart + 2]) == 0x65 // 'e'
                && lower(bytes[nameStart + 3]) == 0x66 // 'f'

            while i < count, isSpace(bytes[i]) { i += 1 }
            guard i < count, bytes[i] == 0x3D /* = */ else {
                if nameLen == 0 { i += 1 }
                continue
            }
            i += 1 // consume '='
            while i < count, isSpace(bytes[i]) { i += 1 }
            guard i < count else { break }

            let valStart: Int
            let valEnd: Int
            let quote = bytes[i]
            if quote == 0x22 /* " */ || quote == 0x27 /* ' */ {
                i += 1
                valStart = i
                while i < count, bytes[i] != quote { i += 1 }
                valEnd = i
                if i < count { i += 1 }
            } else if quote == 0x3E /* > */ {
                valStart = i
                valEnd = i
            } else {
                valStart = i
                while i < count, !isSpace(bytes[i]), bytes[i] != 0x3E { i += 1 }
                valEnd = i
            }

            if isHref, href == nil {
                href = decodeBytes(bytes, start: valStart, end: valEnd)
            }
        }
        return (href, lastSlash)
    }

    /// Collects visible text inside `<a ...>...</a>`, stripping inner markup and collapsing whitespace.
    private static func collectAnchorText(
        _ bytes: UnsafeBufferPointer<UInt8>,
        index i: inout Int
    ) -> String {
        let count = bytes.count
        var raw: [UInt8] = []
        raw.reserveCapacity(64)

        while i < count {
            if bytes[i] != 0x3C /* < */ {
                if raw.count < 1024 {
                    raw.append(bytes[i])
                }
                i += 1
                continue
            }

            // Closing </a>
            if i + 2 < count,
               bytes[i + 1] == 0x2F /* / */,
               matchesTag(bytes, at: i + 2, asciiLowercase: [0x61]) {
                i += 3
                skipToTagEnd(bytes, index: &i)
                break
            }

            // Unclosed <a> implicitly closed by the next <a ...>
            if matchesTag(bytes, at: i + 1, asciiLowercase: [0x61]) {
                break
            }

            // Comment inside anchor
            if i + 3 < count,
               bytes[i + 1] == 0x21, bytes[i + 2] == 0x2D, bytes[i + 3] == 0x2D {
                i += 4
                while i + 2 < count {
                    if bytes[i] == 0x2D, bytes[i + 1] == 0x2D, bytes[i + 2] == 0x3E {
                        i += 3
                        break
                    }
                    i += 1
                }
                continue
            }

            // Nested inline/block tag inside anchor (e.g., <span>, <b>, <br>, <ix:nonNumeric>)
            if i + 1 < count, isASCIILetter(bytes[i + 1]) || bytes[i + 1] == 0x2F {
                if matchesTag(bytes, at: i + 1, asciiLowercase: [0x62, 0x72]), // <br>
                   raw.last != 0x20 {
                    raw.append(0x20)
                }
                i += 1
                skipToTagEnd(bytes, index: &i)
                continue
            }

            if raw.count < 1024 {
                raw.append(0x3C)
            }
            i += 1
        }

        guard !raw.isEmpty else { return "" }
        let decoded = raw.contains(0x26)
            ? decodeHTMLEntities(String(decoding: raw, as: UTF8.self))
            : String(decoding: raw, as: UTF8.self)
        return decoded
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // MARK: - Byte Helpers

    @inline(__always)
    private static func matchesTag(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at start: Int,
        asciiLowercase target: [UInt8]
    ) -> Bool {
        let end = start + target.count
        guard end < bytes.count else { return false }
        for offset in 0..<target.count {
            if lower(bytes[start + offset]) != target[offset] { return false }
        }
        return isTagBoundary(bytes[end])
    }

    @inline(__always)
    private static func skipToTagEnd(_ bytes: UnsafeBufferPointer<UInt8>, index i: inout Int) {
        let count = bytes.count
        while i < count, bytes[i] != 0x3E { i += 1 }
        if i < count { i += 1 }
    }

    private static func skipUntilClosingTag(
        _ bytes: UnsafeBufferPointer<UInt8>,
        index i: inout Int,
        asciiLowercase tag: [UInt8]
    ) {
        let count = bytes.count
        while i + 2 + tag.count <= count {
            if bytes[i] == 0x3C, bytes[i + 1] == 0x2F,
               matchesTag(bytes, at: i + 2, asciiLowercase: tag) {
                i += 2 + tag.count
                skipToTagEnd(bytes, index: &i)
                return
            }
            i += 1
        }
        i = count
    }

    private static func decodeBytes(
        _ bytes: UnsafeBufferPointer<UInt8>,
        start: Int,
        end: Int
    ) -> String {
        guard start < end else { return "" }
        let slice = UnsafeBufferPointer(rebasing: bytes[start..<end])
        let raw = String(decoding: slice, as: UTF8.self)
        return slice.contains(0x26 /* & */) ? decodeHTMLEntities(raw) : raw
    }

    static func decodeHTMLEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var out = String()
        out.reserveCapacity(input.utf8.count)
        var cursor = input.startIndex

        while cursor < input.endIndex {
            guard input[cursor] == "&" else {
                out.append(input[cursor])
                cursor = input.index(after: cursor)
                continue
            }
            let afterAmp = input.index(after: cursor)
            var semi = afterAmp
            var steps = 0
            while semi < input.endIndex, input[semi] != ";", input[semi] != "&", steps < 12 {
                semi = input.index(after: semi)
                steps += 1
            }
            if semi < input.endIndex, input[semi] == ";",
               let replacement = resolveEntity(input[afterAmp..<semi]) {
                out.append(replacement)
                cursor = input.index(after: semi)
            } else {
                out.append("&")
                cursor = afterAmp
            }
        }
        return out
    }

    private static func resolveEntity(_ token: Substring) -> Character? {
        switch token {
        case "amp", "AMP": return "&"
        case "lt", "LT": return "<"
        case "gt", "GT": return ">"
        case "quot", "QUOT": return "\""
        case "apos", "#39": return "'"
        case "nbsp", "NBSP": return " "
        case "ndash": return "–"
        case "mdash": return "—"
        default:
            if token.hasPrefix("#x") || token.hasPrefix("#X") {
                if let code = UInt32(token.dropFirst(2), radix: 16),
                   let scalar = UnicodeScalar(code) {
                    return Character(scalar)
                }
            } else if token.hasPrefix("#") {
                if let code = UInt32(token.dropFirst(), radix: 10),
                   let scalar = UnicodeScalar(code) {
                    return Character(scalar)
                }
            }
            return nil
        }
    }

    @inline(__always)
    private static func lower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? (b + 32) : b
    }

    @inline(__always)
    private static func isASCIILetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    @inline(__always)
    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C
    }

    @inline(__always)
    private static func isTagBoundary(_ b: UInt8) -> Bool {
        isSpace(b) || b == 0x2F || b == 0x3E
    }

    @inline(__always)
    private static func isAttrNameChar(_ b: UInt8) -> Bool {
        !isSpace(b) && b != 0x3D && b != 0x3E && b != 0x2F && b != 0x22 && b != 0x27
    }
}

/// Parses SEC EDGAR's official `{accessionNo}-index.htm` `<table class="tableFile" summary="Document Format Files">`
/// so exhibits are discovered reliably even when the primary S-1 body has zero `<a href>` hyperlinks.
enum EDGARIndexParser {
    static func parseDocumentFormatFiles(_ htmlData: Data) -> [Filing.DocumentFormatFile] {
        let html = String(decoding: htmlData, as: UTF8.self)
        let tableSlice: Substring
        if let marker = html.range(of: "Document Format Files", options: .caseInsensitive),
           let closeTable = html[marker.upperBound...].range(of: "</table>", options: .caseInsensitive) {
            tableSlice = html[marker.upperBound..<closeTable.lowerBound]
        } else {
            tableSlice = html[...]
        }

        var results: [Filing.DocumentFormatFile] = []
        var cursor = tableSlice.startIndex
        while let trOpen = tableSlice[cursor...].range(of: "<tr", options: .caseInsensitive),
              let trStart = tableSlice[trOpen.upperBound...].firstIndex(of: ">"),
              let trClose = tableSlice[trStart...].range(of: "</tr>", options: .caseInsensitive) {
            let rowContent = tableSlice[tableSlice.index(after: trStart)..<trClose.lowerBound]
            cursor = trClose.upperBound

            let cells = extractTDs(from: rowContent)
            guard cells.count >= 4 else { continue }

            let scannedDocCell = HTMLLinkScanner.scan(Data(cells[2].utf8))
            guard let rawHref = scannedDocCell.links.first?.href.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawHref.isEmpty else {
                continue
            }

            let base = URL(string: "https://www.sec.gov")!
            let fullURL = URL(string: rawHref, relativeTo: base)?.absoluteURL.absoluteString ?? rawHref
            let desc = plainText(from: cells[1])
            let docType = plainText(from: cells[3])

            results.append(Filing.DocumentFormatFile(
                description: desc,
                documentUrl: fullURL,
                type: docType
            ))
        }
        return results
    }

    private static func extractTDs(from row: Substring) -> [Substring] {
        var cells: [Substring] = []
        var pos = row.startIndex
        while let tdOpen = row[pos...].range(of: "<td", options: .caseInsensitive),
              let tdBodyStart = row[tdOpen.upperBound...].firstIndex(of: ">"),
              let tdClose = row[tdBodyStart...].range(of: "</td>", options: .caseInsensitive) {
            cells.append(row[row.index(after: tdBodyStart)..<tdClose.lowerBound])
            pos = tdClose.upperBound
        }
        return cells
    }

    private static func plainText(from htmlFragment: Substring) -> String {
        var stripped = String()
        stripped.reserveCapacity(htmlFragment.count)
        var insideTag = false
        for ch in htmlFragment {
            if ch == "<" {
                insideTag = true
            } else if ch == ">" {
                insideTag = false
                stripped.append(" ")
            } else if !insideTag {
                stripped.append(ch)
            }
        }
        let decoded = HTMLLinkScanner.decodeHTMLEntities(stripped)
        return decoded
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
