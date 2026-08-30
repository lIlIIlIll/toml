// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*

public enum TomlFormatMode {
    Readable | Canonical
}

/// Pure formatter. preview() returns non-overlapping edits and apply() routes
/// those edits through the document's atomic revision check.
public class TomlFormatter {
    public let style: TomlStyle
    public let mode: TomlFormatMode

    public init(
        style!: TomlStyle = TomlStyle.readable,
        mode!: TomlFormatMode = TomlFormatMode.Readable
    ) {
        this.style = style
        this.mode = mode
    }

    public func preview(document: TomlDocument): TomlOutcome<ArrayList<TomlTextEdit>> {
        if (document.hasErrors) {
            let diagnostics = document.diagnostics()
            diagnostics.add(TomlDiagnostic("format_invalid_document", TomlSeverity.Error,
                "formatting requires a document without TOML errors"))
            return TomlOutcome<ArrayList<TomlTextEdit>>.Failure(diagnostics)
        }
        let edits = ArrayList<TomlTextEdit>()
        let bytes = document.sourceBytes()
        let newline = match (style.newline) {
            case TomlNewline.Lf => "\n"
            case TomlNewline.CrLf => "\r\n"
        }
        let semantic = document.semantic().getOrThrow()
        for (node in document.nodes()) {
            let current = tomlDecodeUtf8(bytes, node.span.start, node.span.end, false)
            var desired = current
            if (node.kind == TomlSyntaxKind.KeyValue) {
                desired = tomlFormatStatement(document, node, semantic, style, mode)
            } else if (node.kind == TomlSyntaxKind.TableHeader ||
                node.kind == TomlSyntaxKind.ArrayTableHeader) {
                desired = tomlFormatHeader(document, node)
            } else if (node.kind == TomlSyntaxKind.Whitespace || node.kind == TomlSyntaxKind.Comment) {
                desired = tomlFormatTriviaLine(current, newline,
                    style.finalNewline || node.span.end < document.byteLength)
            }
            if (desired != current) { edits.add(TomlTextEdit(node.span, desired)) }
        }
        if (style.finalNewline && document.byteLength > 0 && !tomlEndsWithNewline(bytes)) {
            edits.add(TomlTextEdit(TomlSpan(document.byteLength, document.byteLength), newline))
        }
        TomlOutcome<ArrayList<TomlTextEdit>>.Success(edits, ArrayList<TomlDiagnostic>())
    }

    public func apply(document: TomlDocument): TomlOutcome<TomlDocument> {
        match (preview(document)) {
            case TomlOutcome<ArrayList<TomlTextEdit>>.Failure(diagnostics) =>
                TomlOutcome<TomlDocument>.Failure(diagnostics)
            case TomlOutcome<ArrayList<TomlTextEdit>>.Success(edits, diagnostics) =>
                let batch = TomlEditBatch(document.revision)
                for (edit in edits) { let _ = batch.add(edit) }
                match (document.apply(batch)) {
                    case TomlOutcome<TomlDocument>.Success(formatted, applyDiagnostics) =>
                        let all = diagnostics.clone(); all.add(all: applyDiagnostics)
                        TomlOutcome<TomlDocument>.Success(formatted, all)
                    case TomlOutcome<TomlDocument>.Failure(applyDiagnostics) =>
                        let all = diagnostics.clone(); all.add(all: applyDiagnostics)
                        TomlOutcome<TomlDocument>.Failure(all)
                }
        }
    }
}

public func formatTomlDocument(
    document: TomlDocument,
    style!: TomlStyle = TomlStyle.readable,
    mode!: TomlFormatMode = TomlFormatMode.Readable
): TomlOutcome<TomlDocument> {
    TomlFormatter(style: style, mode: mode).apply(document)
}

private func tomlLookupSemanticValue(root: TomlTable, path: TomlPath): Option<TomlValue> {
    let segments = path.segments()
    var current: TomlValue = root
    for (segment in segments) {
        match (segment) {
            case TomlPathSegment.Key(key) =>
                match (current) {
                    case table: TomlTable =>
                        match (table.get(key)) {
                            case Some(next) => current = next
                            case None => return None<TomlValue>
                        }
                    case _ => return None<TomlValue>
                }
            case TomlPathSegment.Index(index) =>
                match (current) {
                    case array: TomlArray =>
                        match (array.get(index)) {
                            case Some(next) => current = next
                            case None => return None<TomlValue>
                        }
                    case _ => return None<TomlValue>
                }
        }
    }
    Some(current)
}

private func tomlFormatStatement(
    document: TomlDocument,
    node: TomlSyntaxNode,
    root: TomlTable,
    style: TomlStyle,
    mode: TomlFormatMode
): String {
    let bytes = document.sourceBytes()
    let raw = tomlDecodeUtf8(bytes, node.span.start, node.span.end, false)
    if (raw.contains("\n") || raw.contains("\r")) { return raw }
    let keyNode = match (node.child(TomlSyntaxKind.Key)) {
        case Some(value) => value
        case None => return raw
    }
    let path = match (node.path) {
        case Some(value) => value
        case None => return raw
    }
    let semanticValue = match (tomlLookupSemanticValue(root, path)) {
        case Some(value) => value
        case None => return raw
    }
    let key = tomlDecodeUtf8(bytes, keyNode.span.start, keyNode.span.end, false).trimAscii()
    let encodeStyle = match (mode) {
        case TomlFormatMode.Readable => style
        case TomlFormatMode.Canonical => TomlStyle(indent: style.indent,
            maxWidth: style.maxWidth, newline: style.newline, finalNewline: false)
    }
    match (formatTomlValue(semanticValue,
        options: TomlEncodeOptions(version: document.options.version,
            integerMode: document.options.integerMode, style: encodeStyle))) {
        case TomlOutcome<String>.Success(valueText, _) => "${key} = ${valueText}"
        case TomlOutcome<String>.Failure(_) => raw
    }
}

private func tomlFormatHeader(document: TomlDocument, node: TomlSyntaxNode): String {
    let bytes = document.sourceBytes()
    let raw = tomlDecodeUtf8(bytes, node.span.start, node.span.end, false)
    if (raw.contains("\n") || raw.contains("\r")) { return raw }
    match (node.child(TomlSyntaxKind.Key)) {
        case None => raw
        case Some(keyNode) =>
            let key = tomlDecodeUtf8(bytes, keyNode.span.start, keyNode.span.end, false).trimAscii()
            if (node.kind == TomlSyntaxKind.ArrayTableHeader) { "[[${key}]]" }
            else { "[${key}]" }
    }
}

private func tomlFormatTriviaLine(value: String, newline: String, retainFinalNewline: Bool): String {
    var content = value
    var hadNewline = false
    if (content.endsWith("\r\n")) {
        content = content[0..content.size - 2]
        hadNewline = true
    } else if (content.endsWith("\n") || content.endsWith("\r")) {
        content = content[0..content.size - 1]
        hadNewline = true
    }
    while (content.endsWith(" ") || content.endsWith("\t")) {
        content = content[0..content.size - 1]
    }
    if (hadNewline && retainFinalNewline) { content + newline } else { content }
}

private func tomlEndsWithNewline(bytes: Array<Byte>): Bool {
    !bytes.isEmpty() && (bytes[bytes.size - 1] == b'\n' || bytes[bytes.size - 1] == b'\r')
}
