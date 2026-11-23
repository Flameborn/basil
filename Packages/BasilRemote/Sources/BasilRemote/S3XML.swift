import Foundation

/// A parsed XML element: name (without namespace prefix), text and children. S3 answers are
/// small trees (listings, errors, upload IDs).
final class XMLNode: @unchecked Sendable {
    let name: String
    var text = ""
    var children: [XMLNode] = []

    init(name: String) { self.name = name }

    /// The first child with this name.
    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }

    /// Every child with this name.
    func all(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }

    /// The text of the first child with this name.
    func value(_ name: String) -> String? { child(name)?.text }

    static func parse(_ data: Data) -> XMLNode? {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = XMLNode(name: local)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }
    }
}

/// An S3 error answer: `<Error><Code>NoSuchKey</Code><Message>...</Message></Error>`.
struct S3ErrorBody: Sendable {
    var code: String
    var message: String
    /// AuthorizationHeaderMalformed and PermanentRedirect name the bucket's region.
    var region: String?

    init?(_ data: Data) {
        guard data.first(where: { !$0.isWhitespace }) == UInt8(ascii: "<"),
              let root = XMLNode.parse(data), root.name == "Error" else { return nil }
        code = root.value("Code") ?? ""
        message = root.value("Message") ?? ""
        region = root.value("Region")
    }
}

private extension UInt8 {
    var isWhitespace: Bool { self == 0x20 || self == 0x0a || self == 0x0d || self == 0x09 }
}

enum S3Dates {
    /// "2026-11-23T10:15:30.000Z" in listings.
    static func iso(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// "Mon, 23 Nov 2026 10:15:30 GMT" in Last-Modified.
    static func http(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
