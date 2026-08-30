// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*

/// A raw byte edit against a half-open span in one base revision.
public class TomlTextEdit <: ToString {
    public let span: TomlSpan
    private let replacement: Array<Byte>

    public init(span: TomlSpan, replacement: Array<Byte>) {
        this.span = span
        this.replacement = replacement.clone()
    }

    public init(span: TomlSpan, replacement: String) {
        this.span = span
        this.replacement = tomlCloneStringBytes(replacement)
    }

    public prop replacementSize: Int64 { get() { replacement.size } }
    public func replacementBytes(): Array<Byte> { replacement.clone() }
    public func toString(): String { "replace ${span} with ${replacement.size} bytes" }
}

/// A non-overlapping set of edits tied to one immutable document revision.
public class TomlEditBatch {
    public let baseRevision: Int64
    private let pending: ArrayList<TomlTextEdit>

    public init(baseRevision: Int64) {
        if (baseRevision < 0) { throw IllegalArgumentException("revision must be non-negative") }
        this.baseRevision = baseRevision
        pending = ArrayList<TomlTextEdit>()
    }

    public prop size: Int64 { get() { pending.size } }

    public func add(edit: TomlTextEdit): TomlEditBatch {
        var position: Int64 = pending.size
        for (index in 0..pending.size) {
            let current = pending[index]
            if (edit.span.start < current.span.start ||
                (edit.span.start == current.span.start && edit.span.end < current.span.end)) {
                position = index
                break
            }
        }
        pending.add(edit, at: position)
        this
    }

    public func replace(span: TomlSpan, replacement: String): TomlEditBatch {
        add(TomlTextEdit(span, replacement))
    }

    public func replace(span: TomlSpan, replacement: Array<Byte>): TomlEditBatch {
        add(TomlTextEdit(span, replacement))
    }

    public func insert(offset: Int64, text: String): TomlEditBatch {
        replace(TomlSpan(offset, offset), text)
    }

    public func insert(offset: Int64, bytes: Array<Byte>): TomlEditBatch {
        replace(TomlSpan(offset, offset), bytes)
    }

    public func remove(span: TomlSpan): TomlEditBatch { replace(span, Array<Byte>()) }

    public func edits(): ArrayList<TomlTextEdit> {
        let result = ArrayList<TomlTextEdit>()
        for (edit in pending) {
            result.add(TomlTextEdit(edit.span, edit.replacementBytes()))
        }
        result
    }
}

/// Single-writer transaction over an immutable base document. The session
/// itself is intentionally not thread-safe.
public class TomlEditSession {
    public let base: TomlDocument
    private let batch: TomlEditBatch
    private var closed: Bool = false

    init(base: TomlDocument) {
        this.base = base
        batch = TomlEditBatch(base.revision)
    }

    public prop isClosed: Bool { get() { closed } }
    public prop editCount: Int64 { get() { batch.size } }

    public func add(edit: TomlTextEdit): TomlEditSession {
        ensureOpen()
        let _ = batch.add(edit)
        this
    }

    public func replace(span: TomlSpan, replacement: String): TomlEditSession {
        add(TomlTextEdit(span, replacement))
    }

    public func replace(span: TomlSpan, replacement: Array<Byte>): TomlEditSession {
        add(TomlTextEdit(span, replacement))
    }

    public func insert(offset: Int64, text: String): TomlEditSession {
        replace(TomlSpan(offset, offset), text)
    }

    public func insert(offset: Int64, bytes: Array<Byte>): TomlEditSession {
        replace(TomlSpan(offset, offset), bytes)
    }

    public func remove(span: TomlSpan): TomlEditSession {
        replace(span, Array<Byte>())
    }

    public func preview(): TomlOutcome<TomlDocument> {
        if (closed) {
            let diagnostics = ArrayList<TomlDiagnostic>()
            diagnostics.add(TomlDiagnostic("edit_session_closed", TomlSeverity.Error,
                "the edit session is already closed"))
            return TomlOutcome<TomlDocument>.Failure(diagnostics)
        }
        base.apply(batch)
    }

    public func commit(): TomlOutcome<TomlDocument> {
        let result = preview()
        if (result.isSuccess()) { closed = true }
        result
    }

    public func cancel(): Unit { closed = true }

    private func ensureOpen(): Unit {
        if (closed) { throw IllegalStateException("the TOML edit session is already closed") }
    }
}

func tomlValidateTextEdits(
    source: Array<Byte>,
    edits: ArrayList<TomlTextEdit>,
    options: TomlParseOptions
): Option<TomlDiagnostic> {
    var previousEnd: Int64 = -1
    var previousWasInsertion: Bool = false
    for (edit in edits) {
        if (edit.span.end > source.size) {
            return Some(TomlDiagnostic("edit_out_of_bounds", TomlSeverity.Error,
                "edit span ${edit.span} is outside a ${source.size}-byte document",
                primarySpan: Some(edit.span)))
        }
        let insertion = edit.span.length == 0
        if (previousEnd > edit.span.start ||
            (previousEnd == edit.span.start && previousWasInsertion && insertion)) {
            return Some(TomlDiagnostic("overlapping_edits", TomlSeverity.Error,
                "edit spans must be non-overlapping and unambiguous",
                primarySpan: Some(edit.span)))
        }
        if (!tomlIsUtf8Boundary(source, edit.span.start) ||
            !tomlIsUtf8Boundary(source, edit.span.end)) {
            return Some(TomlDiagnostic("invalid_utf8_boundary", TomlSeverity.Error,
                "an edit boundary splits a UTF-8 sequence", primarySpan: Some(edit.span)))
        }
        let rejectInvalid = match (options.utf8Policy) {
            case TomlUtf8Policy.Reject => true
            case TomlUtf8Policy.ReplaceInvalid => false
        }
        if (rejectInvalid) {
            let replacement = edit.replacementBytes()
            var index: Int64 = 0
            while (index < replacement.size) {
                let width = tomlValidUtf8Width(replacement, index)
                if (width == 0) {
                    return Some(TomlDiagnostic("invalid_utf8_edit", TomlSeverity.Error,
                        "replacement bytes are not valid UTF-8", primarySpan: Some(edit.span)))
                }
                index += width
            }
        }
        previousEnd = edit.span.end
        previousWasInsertion = insertion
    }
    None<TomlDiagnostic>
}

private func tomlIsUtf8Boundary(source: Array<Byte>, offset: Int64): Bool {
    if (offset < 0 || offset > source.size) { return false }
    if (offset == 0 || offset == source.size) { return true }
    let byte = source[offset]
    !(byte >= 0x80 && byte <= 0xBF)
}
