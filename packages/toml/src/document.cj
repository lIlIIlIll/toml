// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*
import std.io.*

/// An open syntax-kind value. New versions may define additional values without
/// turning matches over this type into a source-compatibility hazard.
public struct TomlSyntaxKind <: Equatable<TomlSyntaxKind> & ToString {
    public let rawValue: Int64
    private let label: String

    public init(rawValue: Int64, label!: String = "custom") {
        if (rawValue < 0) { throw IllegalArgumentException("syntax kind must be non-negative") }
        this.rawValue = rawValue
        this.label = label
    }

    public static let Document = TomlSyntaxKind(1, label: "document")
    public static let KeyValue = TomlSyntaxKind(2, label: "key_value")
    public static let TableHeader = TomlSyntaxKind(3, label: "table_header")
    public static let ArrayTableHeader = TomlSyntaxKind(4, label: "array_table_header")
    public static let Key = TomlSyntaxKind(5, label: "key")
    public static let Value = TomlSyntaxKind(6, label: "value")
    public static let Comment = TomlSyntaxKind(7, label: "comment")
    public static let Whitespace = TomlSyntaxKind(8, label: "whitespace")
    public static let Error = TomlSyntaxKind(9, label: "error")

    public operator func ==(other: TomlSyntaxKind): Bool { rawValue == other.rawValue }
    public operator func !=(other: TomlSyntaxKind): Bool { !(this == other) }
    public func toString(): String { label }
}

/// Stable identity for a syntax node that was structurally reused.
public struct TomlNodeId <: Equatable<TomlNodeId> & Hashable & ToString {
    public let value: Int64

    public init(value: Int64) {
        if (value <= 0) { throw IllegalArgumentException("node id must be positive") }
        this.value = value
    }

    public operator func ==(other: TomlNodeId): Bool { value == other.value }
    public operator func !=(other: TomlNodeId): Bool { !(this == other) }
    public func hashCode(): Int64 { value }
    public func toString(): String { value.toString() }
}

/// An immutable, read-only syntax node.
public class TomlSyntaxNode <: ToString {
    public let id: TomlNodeId
    public let kind: TomlSyntaxKind
    public let span: TomlSpan
    public let path: Option<TomlPath>
    private let childNodes: ArrayList<TomlSyntaxNode>

    init(
        id: TomlNodeId,
        kind: TomlSyntaxKind,
        span: TomlSpan,
        children!: Collection<TomlSyntaxNode> = ArrayList<TomlSyntaxNode>(),
        path!: Option<TomlPath> = None<TomlPath>
    ) {
        this.id = id
        this.kind = kind
        this.span = span
        this.childNodes = ArrayList<TomlSyntaxNode>(children)
        this.path = path
    }

    public prop childCount: Int64 { get() { childNodes.size } }
    public func children(): ArrayList<TomlSyntaxNode> { childNodes.clone() }

    public func child(kind: TomlSyntaxKind): Option<TomlSyntaxNode> {
        for (node in childNodes) {
            if (node.kind == kind) { return Some(node) }
        }
        None<TomlSyntaxNode>
    }

    public func toString(): String { "${kind}#${id}@${span}" }
}

/// A handle is valid only for the document revision that created it.
public struct TomlNodeHandle <: Equatable<TomlNodeHandle> & ToString {
    public let revision: Int64
    public let id: TomlNodeId

    public init(revision: Int64, id: TomlNodeId) {
        if (revision < 0) { throw IllegalArgumentException("revision must be non-negative") }
        this.revision = revision
        this.id = id
    }

    public operator func ==(other: TomlNodeHandle): Bool {
        revision == other.revision && id == other.id
    }
    public operator func !=(other: TomlNodeHandle): Bool { !(this == other) }
    public func toString(): String { "${revision}:${id}" }
}

class TomlTextPiece {
    let storage: Array<Byte>
    let start: Int64
    let length: Int64

    init(storage: Array<Byte>, start: Int64, length: Int64) {
        this.storage = storage
        this.start = start
        this.length = length
    }
}

/// Persistent piece sequence. Existing byte arrays are shared by edited
/// revisions, while no mutable array is ever exposed to callers.
class TomlTextRope {
    private let pieces: ArrayList<TomlTextPiece>
    let length: Int64

    init(bytes: Array<Byte>) {
        let owned = bytes.clone()
        pieces = ArrayList<TomlTextPiece>()
        if (!owned.isEmpty()) { pieces.add(TomlTextPiece(owned, 0, owned.size)) }
        length = owned.size
    }

    init(pieces: Collection<TomlTextPiece>, length: Int64) {
        this.pieces = ArrayList<TomlTextPiece>(pieces)
        this.length = length
    }

    func materialize(): Array<Byte> {
        let bytes = ArrayList<Byte>()
        for (piece in pieces) {
            if (piece.length > 0) {
                bytes.add(all: piece.storage[piece.start..piece.start + piece.length])
            }
        }
        bytes.toArray()
    }

    func apply(edits: ArrayList<TomlTextEdit>): TomlTextRope {
        let result = ArrayList<TomlTextPiece>()
        var cursor: Int64 = 0
        var newLength: Int64 = length
        for (edit in edits) {
            appendRange(cursor, edit.span.start, result)
            let replacement = edit.replacementBytes()
            if (!replacement.isEmpty()) {
                result.add(TomlTextPiece(replacement, 0, replacement.size))
            }
            newLength += replacement.size - edit.span.length
            cursor = edit.span.end
        }
        appendRange(cursor, length, result)
        TomlTextRope(result, newLength)
    }

    private func appendRange(from: Int64, to: Int64, output: ArrayList<TomlTextPiece>): Unit {
        if (from >= to) { return }
        var logical: Int64 = 0
        for (piece in pieces) {
            let pieceEnd = logical + piece.length
            if (pieceEnd <= from) {
                logical = pieceEnd
                continue
            }
            if (logical >= to) { break }
            let localStart = if (from > logical) { from - logical } else { 0 }
            let localEnd = if (to < pieceEnd) { to - logical } else { piece.length }
            if (localEnd > localStart) {
                output.add(TomlTextPiece(piece.storage, piece.start + localStart, localEnd - localStart))
            }
            logical = pieceEnd
        }
    }
}

/// A lossless parse result. Ordinary TOML errors retain a document; fatal
/// input/UTF-8/resource failures return no document.
public class TomlDocumentParseResult {
    public let document: Option<TomlDocument>
    private let reportedDiagnostics: ArrayList<TomlDiagnostic>

    init(document: Option<TomlDocument>, diagnostics: Collection<TomlDiagnostic>) {
        this.document = document
        this.reportedDiagnostics = tomlCloneDiagnostics(diagnostics)
    }

    public prop hasDocument: Bool { get() { document.isSome() } }
    public prop isFatal: Bool { get() { document.isNone() } }
    public prop hasErrors: Bool { get() { tomlHasErrors(reportedDiagnostics) } }
    public func diagnostics(): ArrayList<TomlDiagnostic> { tomlCloneDiagnostics(reportedDiagnostics) }

    public func getOrThrow(): TomlDocument {
        match (document) {
            case Some(value) => value
            case None => throw TomlException.fromDiagnostics(reportedDiagnostics)
        }
    }
}

/// Immutable and reusable parser for the lossless document model.
public class TomlDocumentParser {
    public let options: TomlParseOptions

    public init(options!: TomlParseOptions = TomlParseOptions.defaults) {
        this.options = options
    }

    public func parse(text: String): TomlDocumentParseResult {
        parse(tomlCloneStringBytes(text))
    }

    public func parse(bytes: Array<Byte>): TomlDocumentParseResult {
        tomlParseDocumentBytes(bytes.clone(), options, 0, None<TomlDocument>, ArrayList<TomlTextEdit>())
    }

    /// Reads to EOF without closing the caller-owned stream.
    public func parse(input: InputStream): TomlDocumentParseResult {
        let bytes = ArrayList<Byte>()
        let buffer = Array<Byte>(8192, { _ => 0 })
        try {
            while (true) {
                let count = input.read(buffer)
                if (count <= 0) { break }
                bytes.add(all: buffer[0..count])
                if (bytes.size > options.limits.maxInputBytes) {
                    let diagnostics = ArrayList<TomlDiagnostic>()
                    diagnostics.add(TomlDiagnostic("input_too_large", TomlSeverity.Error,
                        "input exceeds ${options.limits.maxInputBytes} bytes",
                        primarySpan: Some(TomlSpan(0, bytes.size))))
                    return TomlDocumentParseResult(None<TomlDocument>, diagnostics)
                }
            }
        } catch (exception: Exception) {
            let diagnostics = ArrayList<TomlDiagnostic>()
            diagnostics.add(TomlDiagnostic("stream_read_error", TomlSeverity.Error,
                "failed to read TOML input stream: ${exception.message}"))
            return TomlDocumentParseResult(None<TomlDocument>, diagnostics)
        }
        parse(bytes.toArray())
    }
}

public func parseTomlDocument(
    text: String,
    options!: TomlParseOptions = TomlParseOptions.defaults
): TomlDocumentParseResult {
    TomlDocumentParser(options: options).parse(text)
}

public func parseTomlDocument(
    bytes: Array<Byte>,
    options!: TomlParseOptions = TomlParseOptions.defaults
): TomlDocumentParseResult {
    TomlDocumentParser(options: options).parse(bytes)
}

public func parseTomlDocument(
    input: InputStream,
    options!: TomlParseOptions = TomlParseOptions.defaults
): TomlDocumentParseResult {
    TomlDocumentParser(options: options).parse(input)
}

/// Immutable lossless source, syntax, diagnostics, and partial semantic state.
public class TomlDocument {
    private let source: TomlTextRope
    private let syntaxRoot: TomlSyntaxNode
    private let partialSemanticRoot: TomlTable
    private let reportedDiagnostics: ArrayList<TomlDiagnostic>
    let nextNodeId: Int64
    public let revision: Int64
    public let options: TomlParseOptions

    init(
        source: TomlTextRope,
        syntaxRoot: TomlSyntaxNode,
        partialSemanticRoot: TomlTable,
        diagnostics: Collection<TomlDiagnostic>,
        revision: Int64,
        options: TomlParseOptions,
        nextNodeId: Int64
    ) {
        this.source = source
        this.syntaxRoot = syntaxRoot
        this.partialSemanticRoot = partialSemanticRoot
        this.reportedDiagnostics = tomlCloneDiagnostics(diagnostics)
        this.revision = revision
        this.options = options
        this.nextNodeId = nextNodeId
    }

    public prop byteLength: Int64 { get() { source.length } }
    public prop hasErrors: Bool { get() { tomlHasErrors(reportedDiagnostics) } }
    public func sourceBytes(): Array<Byte> { source.materialize() }
    public func text(): String {
        let replaceInvalid = match (options.utf8Policy) {
            case TomlUtf8Policy.ReplaceInvalid => true
            case TomlUtf8Policy.Reject => false
        }
        tomlDecodeUtf8(source.materialize(), 0, source.length, replaceInvalid)
    }
    public func diagnostics(): ArrayList<TomlDiagnostic> { tomlCloneDiagnostics(reportedDiagnostics) }
    public func syntax(): TomlSyntaxNode { syntaxRoot }
    public func nodes(): ArrayList<TomlSyntaxNode> { syntaxRoot.children() }

    /// Returns recovered semantic state, even if the document has errors.
    public func partialRoot(): TomlTable { partialSemanticRoot.deepCopy().asTable() }

    /// Produces semantic state only when no error diagnostic exists.
    public func semantic(): TomlOutcome<TomlTable> {
        if (hasErrors) { TomlOutcome<TomlTable>.Failure(diagnostics()) }
        else { TomlOutcome<TomlTable>.Success(partialRoot(), diagnostics()) }
    }

    public func handle(node: TomlSyntaxNode): TomlNodeHandle {
        match (findNode(node.id)) {
            case Some(_) => TomlNodeHandle(revision, node.id)
            case None => throw IllegalArgumentException("node does not belong to this document")
        }
    }

    public func resolve(handle: TomlNodeHandle): Option<TomlSyntaxNode> {
        if (handle.revision != revision) { return None<TomlSyntaxNode> }
        findNode(handle.id)
    }

    /// Explicitly relocates a handle when its node identity survived an edit.
    public func relocate(handle: TomlNodeHandle): Option<TomlNodeHandle> {
        match (findNode(handle.id)) {
            case Some(_) => Some(TomlNodeHandle(revision, handle.id))
            case None => None<TomlNodeHandle>
        }
    }

    public func findNode(id: TomlNodeId): Option<TomlSyntaxNode> {
        tomlFindSyntaxNode(syntaxRoot, id)
    }

    public func text(node: TomlSyntaxNode): Array<Byte> {
        match (findNode(node.id)) {
            case Some(current) =>
                let bytes = source.materialize()
                bytes[current.span.start..current.span.end].clone()
            case None => throw IllegalArgumentException("node does not belong to this document")
        }
    }

    public func beginEdit(): TomlEditSession { TomlEditSession(this) }

    /// Applies a revision-bound batch atomically. Syntax errors in the new text
    /// remain in the returned document; structural edit failures return Failure.
    public func apply(batch: TomlEditBatch): TomlOutcome<TomlDocument> {
        if (batch.baseRevision != revision) {
            return tomlDocumentEditFailure("stale_revision",
                "edit batch revision ${batch.baseRevision} does not match document revision ${revision}")
        }
        let edits = batch.edits()
        match (tomlValidateTextEdits(source.materialize(), edits, options)) {
            case Some(diagnostic) =>
                let diagnostics = ArrayList<TomlDiagnostic>()
                diagnostics.add(diagnostic)
                return TomlOutcome<TomlDocument>.Failure(diagnostics)
            case None => ()
        }
        let editedSource = source.apply(edits)
        if (editedSource.length > options.limits.maxInputBytes) {
            return tomlDocumentEditFailure("input_too_large",
                "edited input exceeds ${options.limits.maxInputBytes} bytes")
        }
        let parsed = tomlParseInternal(editedSource.materialize(), options)
        if (parsed.fatal) {
            return TomlOutcome<TomlDocument>.Failure(tomlCloneDiagnostics(parsed.diagnostics))
        }
        let document = tomlBuildDocument(editedSource, parsed, revision + 1, options,
            Some(this), edits)
        TomlOutcome<TomlDocument>.Success(document, document.diagnostics())
    }
}

private func tomlParseDocumentBytes(
    bytes: Array<Byte>,
    options: TomlParseOptions,
    revision: Int64,
    previous: Option<TomlDocument>,
    edits: ArrayList<TomlTextEdit>
): TomlDocumentParseResult {
    let parsed = tomlParseInternal(bytes.clone(), options)
    if (parsed.fatal) {
        return TomlDocumentParseResult(None<TomlDocument>, parsed.diagnostics)
    }
    let document = tomlBuildDocument(TomlTextRope(bytes), parsed, revision, options, previous, edits)
    TomlDocumentParseResult(Some(document), document.diagnostics())
}

private func tomlFindSyntaxNode(node: TomlSyntaxNode, id: TomlNodeId): Option<TomlSyntaxNode> {
    if (node.id == id) { return Some(node) }
    for (child in node.children()) {
        match (tomlFindSyntaxNode(child, id)) {
            case Some(found) => return Some(found)
            case None => ()
        }
    }
    None<TomlSyntaxNode>
}

private func tomlCloneDiagnostics(values: Collection<TomlDiagnostic>): ArrayList<TomlDiagnostic> {
    let result = ArrayList<TomlDiagnostic>()
    for (value in values) {
        let labels = ArrayList<TomlDiagnosticLabel>()
        for (label in value.labels) {
            labels.add(TomlDiagnosticLabel(label.span, label.message))
        }
        let path = match (value.path) {
            case Some(item) => Some(TomlPath(item.segments()))
            case None => None<TomlPath>
        }
        result.add(TomlDiagnostic(value.code, value.severity, value.message,
            primarySpan: value.primarySpan, labels: labels, path: path))
    }
    result
}

private func tomlDocumentEditFailure(code: String, message: String): TomlOutcome<TomlDocument> {
    let diagnostics = ArrayList<TomlDiagnostic>()
    diagnostics.add(TomlDiagnostic(code, TomlSeverity.Error, message))
    TomlOutcome<TomlDocument>.Failure(diagnostics)
}

private class TomlReusableNode {
    let node: TomlSyntaxNode
    let mappedSpan: TomlSpan

    init(node: TomlSyntaxNode, mappedSpan: TomlSpan) {
        this.node = node
        this.mappedSpan = mappedSpan
    }
}

private class TomlSyntaxFactory {
    private let reusable = HashMap<String, TomlReusableNode>()
    private var nextId: Int64

    init(previous: Option<TomlDocument>, edits: ArrayList<TomlTextEdit>) {
        nextId = match (previous) {
            case Some(document) => document.nextNodeId
            case None => 1
        }
        match (previous) {
            case Some(document) => collect(document.syntax(), edits)
            case None => ()
        }
    }

    func make(
        kind: TomlSyntaxKind,
        span: TomlSpan,
        children!: Collection<TomlSyntaxNode> = ArrayList<TomlSyntaxNode>(),
        path!: Option<TomlPath> = None<TomlPath>
    ): TomlSyntaxNode {
        let key = tomlReuseKey(kind, span)
        match (reusable.get(key)) {
            case Some(old) => TomlSyntaxNode(old.node.id, kind, span, children: children, path: path)
            case None =>
                let id = TomlNodeId(nextId)
                nextId++
                TomlSyntaxNode(id, kind, span, children: children, path: path)
        }
    }

    func nextValue(): Int64 { nextId }

    private func collect(node: TomlSyntaxNode, edits: ArrayList<TomlTextEdit>): Unit {
        match (tomlMapUnchangedSpan(node.span, edits)) {
            case Some(mapped) =>
                let _ = reusable.add(tomlReuseKey(node.kind, mapped), TomlReusableNode(node, mapped))
            case None => ()
        }
        for (child in node.children()) { collect(child, edits) }
    }
}

private func tomlReuseKey(kind: TomlSyntaxKind, span: TomlSpan): String {
    "${kind.rawValue}:${span.start}:${span.end}"
}

private func tomlMapUnchangedSpan(
    span: TomlSpan,
    edits: ArrayList<TomlTextEdit>
): Option<TomlSpan> {
    var shift: Int64 = 0
    for (edit in edits) {
        if (edit.span.end <= span.start) {
            shift += edit.replacementSize - edit.span.length
            continue
        }
        if (edit.span.start >= span.end) { continue }
        return None<TomlSpan>
    }
    Some(TomlSpan(span.start + shift, span.end + shift))
}

private func tomlBuildDocument(
    source: TomlTextRope,
    parsed: TomlInternalParseResult,
    revision: Int64,
    options: TomlParseOptions,
    previous: Option<TomlDocument>,
    edits: ArrayList<TomlTextEdit>
): TomlDocument {
    let bytes = source.materialize()
    let factory = TomlSyntaxFactory(previous, edits)
    let children = ArrayList<TomlSyntaxNode>()
    var cursor: Int64 = 0
    for (statement in parsed.statements) {
        if (statement.span.start > cursor) {
            tomlAppendTriviaNodes(bytes, cursor, statement.span.start, parsed.diagnostics, factory, children)
        }
        let statementChildren = ArrayList<TomlSyntaxNode>()
        statementChildren.add(factory.make(TomlSyntaxKind.Key, statement.keySpan))
        match (statement.valueSpan) {
            case Some(valueSpan) => statementChildren.add(factory.make(TomlSyntaxKind.Value, valueSpan))
            case None => ()
        }
        let kind = match (statement.kind) {
            case TomlParsedStatementKind.KeyValue => TomlSyntaxKind.KeyValue
            case TomlParsedStatementKind.TableHeader => TomlSyntaxKind.TableHeader
            case TomlParsedStatementKind.ArrayTableHeader => TomlSyntaxKind.ArrayTableHeader
        }
        let path = tomlPathFromKeys(statement.path)
        children.add(factory.make(kind, statement.span, children: statementChildren, path: Some(path)))
        cursor = statement.span.end
    }
    if (cursor < bytes.size) {
        tomlAppendTriviaNodes(bytes, cursor, bytes.size, parsed.diagnostics, factory, children)
    }
    let root = factory.make(TomlSyntaxKind.Document, TomlSpan(0, bytes.size), children: children)
    TomlDocument(source, root, parsed.root, parsed.diagnostics, revision, options, factory.nextValue())
}

private func tomlPathFromKeys(keys: Collection<String>): TomlPath {
    let path = TomlPath()
    var result = path
    for (key in keys) { result = result.withKey(key) }
    result
}

private func tomlAppendTriviaNodes(
    bytes: Array<Byte>,
    start: Int64,
    end: Int64,
    diagnostics: Collection<TomlDiagnostic>,
    factory: TomlSyntaxFactory,
    output: ArrayList<TomlSyntaxNode>
): Unit {
    var cursor = start
    while (cursor < end) {
        let lineStart = cursor
        while (cursor < end && bytes[cursor] != b'\n' && bytes[cursor] != b'\r') { cursor++ }
        if (cursor < end && bytes[cursor] == b'\r') {
            cursor++
            if (cursor < end && bytes[cursor] == b'\n') { cursor++ }
        } else if (cursor < end && bytes[cursor] == b'\n') {
            cursor++
        }
        let span = TomlSpan(lineStart, cursor)
        var kind = if (tomlSpanHasError(span, diagnostics)) {
            TomlSyntaxKind.Error
        } else if (tomlLineIsComment(bytes, lineStart, cursor)) {
            TomlSyntaxKind.Comment
        } else {
            TomlSyntaxKind.Whitespace
        }
        output.add(factory.make(kind, span))
    }
}

private func tomlSpanHasError(span: TomlSpan, diagnostics: Collection<TomlDiagnostic>): Bool {
    for (diagnostic in diagnostics) {
        match ((diagnostic.severity, diagnostic.primarySpan)) {
            case (TomlSeverity.Error, Some(errorSpan)) =>
                if ((errorSpan.start < span.end && errorSpan.end > span.start) ||
                    (errorSpan.start == errorSpan.end && span.contains(errorSpan.start))) { return true }
            case _ => ()
        }
    }
    false
}

private func tomlLineIsComment(bytes: Array<Byte>, start: Int64, end: Int64): Bool {
    var index = start
    while (index < end && (bytes[index] == b' ' || bytes[index] == b'\t')) { index++ }
    index < end && bytes[index] == b'#'
}
