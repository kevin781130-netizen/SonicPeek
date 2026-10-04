import Foundation

/// Strict bounded iXML. Reject DTD/entity declarations before parsing;
/// external entity resolution is disabled at both property and delegate.
public struct IXMLChunk: Equatable, Sendable {
    public let project: String?
    public let scene: String?
    public let tape: String?
    public let track: String?
    public let notes: String?
    public init(project: String?, scene: String?, tape: String?, track: String?, notes: String?) {
        self.project = project; self.scene = scene; self.tape = tape; self.track = track; self.notes = notes
    }
    public static func parse(payload: Data, maxBytes: Int = 1024 * 1024) -> IXMLChunk? {
        guard maxBytes > 0, payload.count <= maxBytes else { return nil }
        var bytes = payload
        while bytes.last == 0 { bytes.removeLast() }
        // iXML is UTF-8. Reject other encodings, DTDs and entities, including
        // internal expansion, before XMLParser can process declarations.
        guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0"),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { return nil }
        let delegate = IXMLDelegate()
        let parser = XMLParser(data: bytes)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, delegate.root == "BWFXML" else { return nil }
        let f = delegate.fields
        return IXMLChunk(project: f["PROJECT"], scene: f["SCENE"], tape: f["TAPE"], track: f["TRACK"] ?? f["NAME"], notes: f["NOTE"])
    }
}
private final class IXMLDelegate: NSObject, XMLParserDelegate {
    var fields: [String: String] = [:]
    var stack: [(name: String, text: String)] = []
    var root: String?
    var invalid = false
    var elements = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        elements += 1
        guard stack.count < 32, elements <= 8192 else { invalid = true; parser.abortParsing(); return }
        if root == nil { root = name }
        stack.append((name, ""))
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
        guard !stack.isEmpty else { return }
        guard stack[stack.count-1].text.utf8.count + text.utf8.count <= 65536 else { invalid = true; parser.abortParsing(); return }
        stack[stack.count-1].text += text
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { invalid = true; parser.abortParsing(); return }
        self.parser(parser, foundCharacters: text)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard let node = stack.popLast() else { return }
        let value = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let direct = stack.count == 1 && stack.first?.name == "BWFXML"
        let trackName = name == "NAME" && stack.last?.name == "TRACK"
        if (direct || trackName), ["PROJECT", "SCENE", "TAPE", "TRACK", "NAME", "NOTE"].contains(name), !value.isEmpty, fields[name] == nil {
            fields[name] = value
        }
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        invalid = true; parser.abortParsing(); return nil
    }
}
