import Foundation

/// One `<response>` of a PROPFIND answer (207 Multi-Status): its href and the properties the
/// server found (those under a propstat with a 2xx status).
struct DAVEntry: Sendable, Equatable {
    /// As sent: percent-encoded, an absolute path or a whole URL.
    var href: String
    var isCollection = false
    var size: Int64?
    var modified: Date?
    var created: Date?
    var etag: String?
    /// Nextcloud's file ID (oc:fileid).
    var fileID: String?
    /// Other properties by "namespace local-name" ("http://nextcloud.org/ns trashbin-filename").
    var other: [String: String] = [:]

    func value(_ namespace: String, _ name: String) -> String? { other[namespace + " " + name] }
}

enum DAVNamespace {
    static let dav = "DAV:"
    static let owncloud = "http://owncloud.org/ns"
    static let nextcloud = "http://nextcloud.org/ns"
}

/// PROPFIND bodies and the parser for their answers.
enum DAVXML {
    /// A PROPFIND body asking for the properties Basil uses; `extra` are more, as
    /// (prefix, local name) with the prefixes "d", "oc" and "nc".
    static func propfind(nextcloud: Bool, extra: [(String, String)] = []) -> Data {
        var props = ["d:resourcetype", "d:getcontentlength", "d:getlastmodified", "d:creationdate", "d:getetag"]
        if nextcloud { props.append("oc:fileid") }
        props += extra.map { "\($0.0):\($0.1)" }
        let text = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns"><d:prop>\(props.map { "<\($0)/>" }.joined())</d:prop></d:propfind>
        """
        return Data(text.utf8)
    }

    /// A PROPPATCH setting the modification date (Nextcloud takes Unix seconds in d:lastmodified).
    static func setModified(seconds: Int) -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propertyupdate xmlns:d="DAV:"><d:set><d:prop><d:lastmodified>\(seconds)</d:lastmodified></d:prop></d:set></d:propertyupdate>
        """.utf8)
    }

    static func parse(_ data: Data) throws -> [DAVEntry] {
        let delegate = MultistatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw DAVParseError(message: parser.parserError?.localizedDescription ?? "unreadable XML")
        }
        return delegate.entries
    }

    struct DAVParseError: Error { var message: String }

    // MARK: Dates

    /// RFC 1123 ("Mon, 23 Nov 2026 08:18:08 GMT"), as getlastmodified has it; also RFC 850 and
    /// asctime, which HTTP allows.
    static func httpDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// ISO 8601 ("2026-11-23T08:18:08Z"), as creationdate has it.
    static func isoDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed)
    }
}

/// Reads a multistatus document. Properties count only from a propstat whose status is 2xx.
private final class MultistatusParser: NSObject, XMLParserDelegate {
    var entries: [DAVEntry] = []

    private var entry: DAVEntry?
    private var propstat: DAVEntry?
    private var propstatStatus: Int?
    private var stack: [(namespace: String, name: String)] = []
    private var text = ""
    /// The property element whose value is being read (a direct child of prop).
    private var property: (namespace: String, name: String)?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let namespace = namespaceURI ?? ""
        let parent = stack.last
        stack.append((namespace, name))
        text = ""
        if namespace == DAVNamespace.dav {
            switch name {
            case "response":
                entry = DAVEntry(href: "")
                return
            case "propstat":
                propstat = DAVEntry(href: "")
                propstatStatus = nil
                return
            case "collection" where property?.namespace == DAVNamespace.dav && property?.name == "resourcetype":
                propstat?.isCollection = true
                return
            default:
                break
            }
        }
        if let parent, parent.namespace == DAVNamespace.dav, parent.name == "prop", propstat != nil {
            property = (namespace, name)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let namespace = namespaceURI ?? ""
        stack.removeLast()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        if let current = property, current.namespace == namespace, current.name == name {
            property = nil
            store(namespace, name, value)
            return
        }
        guard namespace == DAVNamespace.dav else { return }
        switch name {
        case "href" where stack.last?.name == "response":
            entry?.href = value
        case "status" where stack.last?.name == "propstat":
            // "HTTP/1.1 200 OK"
            let parts = value.split(separator: " ")
            propstatStatus = parts.count > 1 ? Int(parts[1]) : nil
        case "propstat":
            if let found = propstat, let status = propstatStatus, (200..<300).contains(status) {
                merge(found)
            }
            propstat = nil
        case "response":
            if let entry { entries.append(entry) }
            entry = nil
        default:
            break
        }
    }

    private func store(_ namespace: String, _ name: String, _ value: String) {
        guard propstat != nil else { return }
        switch (namespace, name) {
        case (DAVNamespace.dav, "resourcetype"):
            break
        case (DAVNamespace.dav, "getcontentlength"):
            propstat?.size = Int64(value)
        case (DAVNamespace.dav, "getlastmodified"):
            propstat?.modified = DAVXML.httpDate(value)
        case (DAVNamespace.dav, "creationdate"):
            propstat?.created = DAVXML.isoDate(value) ?? DAVXML.httpDate(value)
        case (DAVNamespace.dav, "getetag"):
            propstat?.etag = value.isEmpty ? nil : value
        case (DAVNamespace.owncloud, "fileid"):
            propstat?.fileID = value.isEmpty ? nil : value
        default:
            propstat?.other[namespace + " " + name] = value
        }
    }

    private func merge(_ found: DAVEntry) {
        guard entry != nil else { return }
        if found.isCollection { entry?.isCollection = true }
        if let size = found.size { entry?.size = size }
        if let date = found.modified { entry?.modified = date }
        if let date = found.created { entry?.created = date }
        if let etag = found.etag { entry?.etag = etag }
        if let id = found.fileID { entry?.fileID = id }
        entry?.other.merge(found.other) { $1 }
    }
}

/// Server paths and URLs.
enum DAVPath {
    /// Characters left as they are in a path segment; everything else is percent-encoded.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// "/a b/c" -> "/a%20b/c"; the slashes stay.
    static func encode(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? String($0) }
            .joined(separator: "/")
    }

    /// The decoded server path of an href ("http://host/a%20b/" -> "/a b"), without a trailing
    /// slash ("" for the server's top).
    static func decode(_ href: String) -> String {
        var path = Substring(href)
        if let scheme = path.range(of: "://") {
            let afterHost = path[scheme.upperBound...]
            path = afterHost.firstIndex(of: "/").map { afterHost[$0...] } ?? "/"
        }
        if let query = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<query] }
        var decoded = String(path).removingPercentEncoding ?? String(path)
        while decoded.hasSuffix("/") { decoded.removeLast() }
        return decoded
    }

    /// A path typed by the user ("dav/", "/remote.php/dav/files/me/") as a server path without
    /// a trailing slash ("" for the top).
    static func normalized(_ text: String?) -> String {
        var path = (text ?? "").trimmingCharacters(in: .whitespaces)
        if !path.isEmpty, !path.hasPrefix("/") { path = "/" + path }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The parent of a server path ("" has none).
    static func parent(_ path: String) -> String? {
        guard !path.isEmpty, let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<slash])
    }
}
