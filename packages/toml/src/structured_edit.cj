// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*

public enum TomlCommentPolicy {
    Preserve | RemoveLine
}

private func tomlEditSuccess(): TomlOutcome<Unit> {
    TomlOutcome<Unit>.Success((), ArrayList<TomlDiagnostic>())
}

private func tomlEditFailure(code: String, message: String, path: TomlPath): TomlOutcome<Unit> {
    let diagnostics = ArrayList<TomlDiagnostic>()
    diagnostics.add(TomlDiagnostic(code, TomlSeverity.Error, message, path: Some(path)))
    TomlOutcome<Unit>.Failure(diagnostics)
}

private func tomlPathsEqual(left: TomlPath, right: TomlPath): Bool {
    let a = left.segments()
    let b = right.segments()
    if (a.size != b.size) { return false }
    for (index in 0..a.size) {
        match ((a[index], b[index])) {
            case (TomlPathSegment.Key(ak), TomlPathSegment.Key(bk)) =>
                if (ak != bk) { return false }
            case (TomlPathSegment.Index(ai), TomlPathSegment.Index(bi)) =>
                if (ai != bi) { return false }
            case _ => return false
        }
    }
    true
}

private func tomlPathKeys(path: TomlPath): Option<ArrayList<String>> {
    let result = ArrayList<String>()
    for (segment in path.segments()) {
        match (segment) {
            case TomlPathSegment.Key(key) => result.add(key)
            case TomlPathSegment.Index(_) => return None<ArrayList<String>>
        }
    }
    Some(result)
}

private func tomlPathPrefix(keys: ArrayList<String>, size: Int64): TomlPath {
    var path = TomlPath()
    for (index in 0..size) { path = path.withKey(keys[index]) }
    path
}

private func tomlNodePathEquals(node: TomlSyntaxNode, path: TomlPath): Bool {
    match (node.path) {
        case Some(nodePath) => tomlPathsEqual(nodePath, path)
        case None => false
    }
}

private func tomlDiagnosticTargetsPath(diagnostic: TomlDiagnostic, path: TomlPath): Bool {
    match (diagnostic.path) {
        case Some(diagnosticPath) => tomlPathsEqual(diagnosticPath, path)
        case None => false
    }
}

private func tomlSpansIntersect(left: TomlSpan, right: TomlSpan): Bool {
    left.start < right.end && left.end > right.start
}

private func tomlFindHealthyStatement(
    document: TomlDocument,
    path: TomlPath,
    requiredKind: TomlSyntaxKind
): TomlOutcome<TomlSyntaxNode> {
    let matches = ArrayList<TomlSyntaxNode>()
    for (node in document.nodes()) {
        if (node.kind == requiredKind && tomlNodePathEquals(node, path)) { matches.add(node) }
    }
    if (matches.isEmpty()) {
        let diagnostics = ArrayList<TomlDiagnostic>()
        diagnostics.add(TomlDiagnostic("path_not_found", TomlSeverity.Error,
            "no editable TOML node exists at ${path}", path: Some(path)))
        return TomlOutcome<TomlSyntaxNode>.Failure(diagnostics)
    }
    if (matches.size != 1) {
        let diagnostics = ArrayList<TomlDiagnostic>()
        diagnostics.add(TomlDiagnostic("ambiguous_path", TomlSeverity.Error,
            "more than one editable TOML node exists at ${path}", path: Some(path)))
        return TomlOutcome<TomlSyntaxNode>.Failure(diagnostics)
    }
    let target = matches[0]
    for (diagnostic in document.diagnostics()) {
        let isError = match (diagnostic.severity) {
            case TomlSeverity.Error => true
            case _ => false
        }
        if (!isError) { continue }
        if (tomlDiagnosticTargetsPath(diagnostic, path)) {
            let diagnostics = ArrayList<TomlDiagnostic>()
            diagnostics.add(TomlDiagnostic("unhealthy_node", TomlSeverity.Error,
                "the target path participates in a TOML error", path: Some(path)))
            return TomlOutcome<TomlSyntaxNode>.Failure(diagnostics)
        }
        match (diagnostic.primarySpan) {
            case Some(span) =>
                if (tomlSpansIntersect(span, target.span)) {
                    let diagnostics = ArrayList<TomlDiagnostic>()
                    diagnostics.add(TomlDiagnostic("unhealthy_node", TomlSeverity.Error,
                        "the target syntax node overlaps a TOML error", path: Some(path)))
                    return TomlOutcome<TomlSyntaxNode>.Failure(diagnostics)
                }
            case None => ()
        }
    }
    TomlOutcome<TomlSyntaxNode>.Success(target, ArrayList<TomlDiagnostic>())
}

private func tomlStatementLineSpan(document: TomlDocument, node: TomlSyntaxNode): TomlSpan {
    let bytes = document.sourceBytes()
    var end = node.span.end
    while (end < bytes.size && bytes[end] != b'\n' && bytes[end] != b'\r') { end++ }
    if (end < bytes.size && bytes[end] == b'\r') {
        end++
        if (end < bytes.size && bytes[end] == b'\n') { end++ }
    } else if (end < bytes.size && bytes[end] == b'\n') { end++ }
    TomlSpan(node.span.start, end)
}

private func tomlDocumentNewline(document: TomlDocument): String {
    let bytes = document.sourceBytes()
    for (index in 0..bytes.size) {
        if (bytes[index] == b'\n') {
            if (index > 0 && bytes[index - 1] == b'\r') { return "\r\n" }
            return "\n"
        }
    }
    "\n"
}

private func tomlLookupTable(root: TomlTable, keys: ArrayList<String>, count: Int64): Option<TomlTable> {
    var current = root
    for (index in 0..count) {
        match (current.get(keys[index])) {
            case Some(table: TomlTable) => current = table
            case _ => return None<TomlTable>
        }
    }
    Some(current)
}

private func tomlFirstHeaderOffset(document: TomlDocument): Int64 {
    for (node in document.nodes()) {
        if (node.kind == TomlSyntaxKind.TableHeader || node.kind == TomlSyntaxKind.ArrayTableHeader) {
            return node.span.start
        }
    }
    document.byteLength
}

private func tomlHeaderBodyEnd(document: TomlDocument, header: TomlSyntaxNode): Int64 {
    var seen = false
    for (node in document.nodes()) {
        if (node.id == header.id) { seen = true; continue }
        if (seen && (node.kind == TomlSyntaxKind.TableHeader ||
            node.kind == TomlSyntaxKind.ArrayTableHeader)) { return node.span.start }
    }
    document.byteLength
}

private func tomlFindHeaders(document: TomlDocument, path: TomlPath): ArrayList<TomlSyntaxNode> {
    let result = ArrayList<TomlSyntaxNode>()
    for (node in document.nodes()) {
        if (node.kind == TomlSyntaxKind.TableHeader && tomlNodePathEquals(node, path)) {
            result.add(node)
        }
    }
    result
}

private func tomlEnsureInsertionPrefix(document: TomlDocument, offset: Int64, text: String): String {
    if (offset == 0 || text.isEmpty()) { return text }
    let bytes = document.sourceBytes()
    if (bytes[offset - 1] == b'\n' || bytes[offset - 1] == b'\r') { return text }
    tomlDocumentNewline(document) + text
}

private func tomlLastKeySegmentSpan(document: TomlDocument, keyNode: TomlSyntaxNode): TomlSpan {
    let bytes = document.sourceBytes()
    var index = keyNode.span.start
    var segmentStart = index
    var quoteByte: Byte = 0
    var escaped = false
    while (index < keyNode.span.end) {
        let byte = bytes[index]
        if (quoteByte != 0) {
            if (quoteByte == b'\"' && !escaped && byte == b'\\') { escaped = true; index++; continue }
            if (!escaped && byte == quoteByte) { quoteByte = 0 }
            escaped = false
        } else if (byte == b'\"' || byte == b'\'') {
            quoteByte = byte
        } else if (byte == b'.') {
            segmentStart = index + 1
        }
        index++
    }
    while (segmentStart < keyNode.span.end &&
        (bytes[segmentStart] == b' ' || bytes[segmentStart] == b'\t')) { segmentStart++ }
    var segmentEnd = keyNode.span.end
    while (segmentEnd > segmentStart &&
        (bytes[segmentEnd - 1] == b' ' || bytes[segmentEnd - 1] == b'\t')) { segmentEnd-- }
    TomlSpan(segmentStart, segmentEnd)
}

extend TomlEditSession {
    /// Replaces only the value token of one healthy, unique key/value node.
    public func replaceValue(path: TomlPath, value: TomlValue): TomlOutcome<Unit> {
        if (isClosed) { return tomlEditFailure("edit_session_closed", "the edit session is closed", path) }
        match (tomlFindHealthyStatement(base, path, TomlSyntaxKind.KeyValue)) {
            case TomlOutcome<TomlSyntaxNode>.Failure(diagnostics) => TomlOutcome<Unit>.Failure(diagnostics)
            case TomlOutcome<TomlSyntaxNode>.Success(node, _) =>
                match (node.child(TomlSyntaxKind.Value)) {
                    case None => tomlEditFailure("missing_value_node", "the key/value node has no value token", path)
                    case Some(valueNode) =>
                        match (formatTomlValue(value)) {
                            case TomlOutcome<String>.Failure(diagnostics) => TomlOutcome<Unit>.Failure(diagnostics)
                            case TomlOutcome<String>.Success(text, diagnostics) =>
                                let _ = add(TomlTextEdit(valueNode.span, text))
                                TomlOutcome<Unit>.Success((), diagnostics)
                        }
                }
        }
    }

    public func replaceValueOrThrow(path: TomlPath, value: TomlValue): TomlEditSession {
        replaceValue(path, value).getOrThrow()
        this
    }

    /// Inserts a missing value. Existing parents are reused; createParents
    /// permits a new explicit table header when no parent exists.
    public func insertValue(
        path: TomlPath,
        value: TomlValue,
        createParents!: Bool = false
    ): TomlOutcome<Unit> {
        if (isClosed) { return tomlEditFailure("edit_session_closed", "the edit session is closed", path) }
        match (tomlPathKeys(path)) {
            case None => return tomlEditFailure("unsupported_path", "document edits require key-only paths", path)
            case Some(keys) =>
                if (keys.isEmpty()) { return tomlEditFailure("empty_path", "cannot insert the document root", path) }
                for (node in base.nodes()) {
                    if (node.kind == TomlSyntaxKind.KeyValue && tomlNodePathEquals(node, path)) {
                        return tomlEditFailure("path_exists", "a value already exists at ${path}", path)
                    }
                }
                let rendered = formatTomlValue(value)
                if (!rendered.isSuccess()) { return TomlOutcome<Unit>.Failure(rendered.diagnostics()) }
                let valueText = rendered.getOrThrow()
                let newline = tomlDocumentNewline(base)
                let parentCount = keys.size - 1
                if (parentCount == 0) {
                    let offset = tomlFirstHeaderOffset(base)
                    let text = tomlEnsureInsertionPrefix(base, offset,
                        "${tomlRenderKey(keys[0])} = ${valueText}${newline}")
                    let _ = add(TomlTextEdit(TomlSpan(offset, offset), text))
                    return tomlEditSuccess()
                }
                let parentPath = tomlPathPrefix(keys, parentCount)
                let headers = tomlFindHeaders(base, parentPath)
                if (headers.size > 1) {
                    return tomlEditFailure("ambiguous_parent", "the parent table is not unique", parentPath)
                }
                if (headers.size == 1) {
                    let offset = tomlHeaderBodyEnd(base, headers[0])
                    let text = tomlEnsureInsertionPrefix(base, offset,
                        "${tomlRenderKey(keys[keys.size - 1])} = ${valueText}${newline}")
                    let _ = add(TomlTextEdit(TomlSpan(offset, offset), text))
                    return tomlEditSuccess()
                }
                let root = base.partialRoot()
                if (tomlLookupTable(root, keys, parentCount).isSome()) {
                    let offset = tomlFirstHeaderOffset(base)
                    let text = tomlEnsureInsertionPrefix(base, offset,
                        "${tomlRenderKeyPath(keys)} = ${valueText}${newline}")
                    let _ = add(TomlTextEdit(TomlSpan(offset, offset), text))
                    return tomlEditSuccess()
                }
                if (!createParents) {
                    return tomlEditFailure("parent_not_found",
                        "parent table ${parentPath} does not exist", parentPath)
                }
                let offset = base.byteLength
                let headerKeys = ArrayList<String>()
                for (index in 0..parentCount) { headerKeys.add(keys[index]) }
                var text = "[${tomlRenderKeyPath(headerKeys)}]${newline}" +
                    "${tomlRenderKey(keys[keys.size - 1])} = ${valueText}${newline}"
                if (offset > 0) { text = tomlEnsureInsertionPrefix(base, offset, text) }
                let _ = add(TomlTextEdit(TomlSpan(offset, offset), text))
                tomlEditSuccess()
        }
    }

    public func upsertValue(
        path: TomlPath,
        value: TomlValue,
        createParents!: Bool = false
    ): TomlOutcome<Unit> {
        for (node in base.nodes()) {
            if (node.kind == TomlSyntaxKind.KeyValue && tomlNodePathEquals(node, path)) {
                return replaceValue(path, value)
            }
        }
        insertValue(path, value, createParents: createParents)
    }

    public func removeValue(
        path: TomlPath,
        comments!: TomlCommentPolicy = TomlCommentPolicy.Preserve,
        pruneEmptyParents!: Bool = false
    ): TomlOutcome<Unit> {
        if (isClosed) { return tomlEditFailure("edit_session_closed", "the edit session is closed", path) }
        match (tomlFindHealthyStatement(base, path, TomlSyntaxKind.KeyValue)) {
            case TomlOutcome<TomlSyntaxNode>.Failure(diagnostics) => TomlOutcome<Unit>.Failure(diagnostics)
            case TomlOutcome<TomlSyntaxNode>.Success(node, _) =>
                let span = match (comments) {
                    case TomlCommentPolicy.Preserve => node.span
                    case TomlCommentPolicy.RemoveLine => tomlStatementLineSpan(base, node)
                }
                let _ = add(TomlTextEdit(span, Array<Byte>()))
                if (pruneEmptyParents) { tomlScheduleEmptyParentPruning(this, path, comments) }
                tomlEditSuccess()
        }
    }

    public func renameKey(path: TomlPath, newName: String): TomlOutcome<Unit> {
        if (newName.isEmpty()) { return tomlEditFailure("empty_key", "a renamed key must not be empty", path) }
        match (tomlFindHealthyStatement(base, path, TomlSyntaxKind.KeyValue)) {
            case TomlOutcome<TomlSyntaxNode>.Failure(diagnostics) => TomlOutcome<Unit>.Failure(diagnostics)
            case TomlOutcome<TomlSyntaxNode>.Success(node, _) =>
                match (node.child(TomlSyntaxKind.Key)) {
                    case Some(keyNode) =>
                        let _ = add(TomlTextEdit(tomlLastKeySegmentSpan(base, keyNode), tomlRenderKey(newName)))
                        tomlEditSuccess()
                    case None => tomlEditFailure("missing_key_node", "the statement has no key token", path)
                }
        }
    }

    /// Moves one complete statement line before another, preserving its bytes.
    public func moveBefore(path: TomlPath, before: TomlPath): TomlOutcome<Unit> {
        let sourceOutcome = tomlFindHealthyStatement(base, path, TomlSyntaxKind.KeyValue)
        if (!sourceOutcome.isSuccess()) { return TomlOutcome<Unit>.Failure(sourceOutcome.diagnostics()) }
        let targetOutcome = tomlFindHealthyStatement(base, before, TomlSyntaxKind.KeyValue)
        if (!targetOutcome.isSuccess()) { return TomlOutcome<Unit>.Failure(targetOutcome.diagnostics()) }
        let source = sourceOutcome.getOrThrow()
        let target = targetOutcome.getOrThrow()
        if (source.id == target.id) { return tomlEditSuccess() }
        let sourceSpan = tomlStatementLineSpan(base, source)
        if (sourceSpan.contains(target.span.start)) {
            return tomlEditFailure("overlapping_move", "move source and destination overlap", path)
        }
        let bytes = base.sourceBytes()
        let text = tomlDecodeUtf8(bytes, sourceSpan.start, sourceSpan.end, false)
        let _ = add(TomlTextEdit(sourceSpan, Array<Byte>()))
        let _ = add(TomlTextEdit(TomlSpan(target.span.start, target.span.start), text))
        tomlEditSuccess()
    }
}

private func tomlScheduleEmptyParentPruning(
    session: TomlEditSession,
    removedPath: TomlPath,
    comments: TomlCommentPolicy
): Unit {
    match (tomlPathKeys(removedPath)) {
        case None => ()
        case Some(keys) =>
            if (keys.size < 2) { return }
            let root = session.base.partialRoot()
            var childName = keys[keys.size - 1]
            var parentCount = keys.size - 1
            while (parentCount > 0) {
                match (tomlLookupTable(root, keys, parentCount)) {
                    case Some(table) =>
                        if (table.size != 1 || !table.contains(childName)) { return }
                        let parentPath = tomlPathPrefix(keys, parentCount)
                        let headers = tomlFindHeaders(session.base, parentPath)
                        if (headers.size == 1) {
                            let span = match (comments) {
                                case TomlCommentPolicy.Preserve => headers[0].span
                                case TomlCommentPolicy.RemoveLine => tomlStatementLineSpan(session.base, headers[0])
                            }
                            let _ = session.add(TomlTextEdit(span, Array<Byte>()))
                        }
                        childName = keys[parentCount - 1]
                        parentCount--
                    case None => return
                }
            }
    }
}
