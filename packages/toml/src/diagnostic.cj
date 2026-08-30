// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*

/// A zero-based, UTF-8 byte, half-open source span.
public struct TomlSpan <: Equatable<TomlSpan> & ToString {
    public let start: Int64
    public let end: Int64

    public init(start: Int64, end: Int64) {
        if (start < 0 || end < start) {
            throw IllegalArgumentException("a TOML span must satisfy 0 <= start <= end")
        }
        this.start = start
        this.end = end
    }

    public prop length: Int64 { get() { end - start } }

    public func contains(offset: Int64): Bool { offset >= start && offset < end }

    public operator func ==(other: TomlSpan): Bool {
        start == other.start && end == other.end
    }

    public operator func !=(other: TomlSpan): Bool { !(this == other) }

    public func toString(): String { "${start}..${end}" }
}

/// A one-based source position measured in Unicode scalar values.
public struct TomlPosition <: Equatable<TomlPosition> & ToString {
    public let line: Int64
    public let column: Int64

    public init(line: Int64, column: Int64) {
        if (line <= 0 || column <= 0) {
            throw IllegalArgumentException("line and column are one-based")
        }
        this.line = line
        this.column = column
    }

    public operator func ==(other: TomlPosition): Bool {
        line == other.line && column == other.column
    }

    public operator func !=(other: TomlPosition): Bool { !(this == other) }

    public func toString(): String { "${line}:${column}" }
}

/// A zero-based editor position measured in UTF-16 code units.
public struct TomlUtf16Position <: Equatable<TomlUtf16Position> & ToString {
    public let line: Int64
    public let character: Int64

    public init(line: Int64, character: Int64) {
        if (line < 0 || character < 0) {
            throw IllegalArgumentException("UTF-16 line and character must be non-negative")
        }
        this.line = line
        this.character = character
    }

    public operator func ==(other: TomlUtf16Position): Bool {
        line == other.line && character == other.character
    }

    public operator func !=(other: TomlUtf16Position): Bool { !(this == other) }

    public func toString(): String { "${line}:${character}" }
}

public enum TomlSeverity {
    Error | Warning | Info
}

public enum TomlPathSegment {
    Key(String) | Index(Int64)
}

/// A structured value path. Its textual form is intended for diagnostics only.
public class TomlPath <: ToString {
    private let parts: ArrayList<TomlPathSegment>

    public init() { parts = ArrayList<TomlPathSegment>() }

    public init(parts: Collection<TomlPathSegment>) {
        this.parts = ArrayList<TomlPathSegment>(parts)
    }

    public prop size: Int64 { get() { parts.size } }

    public func segments(): ArrayList<TomlPathSegment> { parts.clone() }

    public func withKey(key: String): TomlPath {
        let copy = parts.clone()
        copy.add(TomlPathSegment.Key(key))
        TomlPath(copy)
    }

    public func withIndex(index: Int64): TomlPath {
        let copy = parts.clone()
        copy.add(TomlPathSegment.Index(index))
        TomlPath(copy)
    }

    public func toString(): String {
        let out = StringBuilder("$")
        for (part in parts) {
            match (part) {
                case Key(key) =>
                    if (tomlDiagnosticBareKey(key)) {
                        out.append(".")
                        out.append(key)
                    } else {
                        out.append("[\"")
                        out.append(tomlDiagnosticEscapeKey(key))
                        out.append("\"]")
                    }
                case Index(index) =>
                    out.append("[")
                    out.append(index)
                    out.append("]")
            }
        }
        out.toString()
    }
}

private func tomlDiagnosticBareKey(value: String): Bool {
    if (value.isEmpty()) { return false }
    unsafe {
        for (byte in value.rawData()) {
            if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
                (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-')) {
                return false
            }
        }
    }
    true
}

private func tomlDiagnosticEscapeKey(value: String): String {
    let out = StringBuilder()
    for (rune in value.runes()) {
        if (rune == r'\\') { out.append("\\\\") }
        else if (rune == r'\"') { out.append("\\\"") }
        else { out.append(rune) }
    }
    out.toString()
}

public class TomlDiagnosticLabel {
    public let span: TomlSpan
    public let message: String

    public init(span: TomlSpan, message: String) {
        this.span = span
        this.message = message
    }
}

/// A stable machine-readable code plus English human-readable context.
public class TomlDiagnostic <: ToString {
    public let code: String
    public let severity: TomlSeverity
    public let message: String
    public let primarySpan: Option<TomlSpan>
    public let labels: ArrayList<TomlDiagnosticLabel>
    public let path: Option<TomlPath>

    public init(
        code: String,
        severity: TomlSeverity,
        message: String,
        primarySpan!: Option<TomlSpan> = None<TomlSpan>,
        labels!: Collection<TomlDiagnosticLabel> = ArrayList<TomlDiagnosticLabel>(),
        path!: Option<TomlPath> = None<TomlPath>
    ) {
        if (code.isEmpty()) { throw IllegalArgumentException("diagnostic code must not be empty") }
        this.code = code
        this.severity = severity
        this.message = message
        this.primarySpan = primarySpan
        this.labels = ArrayList<TomlDiagnosticLabel>(labels)
        this.path = path
    }

    public func toString(): String {
        let severityText = match (severity) {
            case Error => "error"
            case Warning => "warning"
            case Info => "info"
        }
        let location = match (primarySpan) {
            case Some(span) => " at bytes ${span}"
            case None => ""
        }
        let pathText = match (path) {
            case Some(valuePath) => " at ${valuePath}"
            case None => ""
        }
        "${severityText}[${code}]${location}${pathText}: ${message}"
    }
}

/// Success and failure both retain diagnostics. A failure never carries T.
public enum TomlOutcome<T> {
    | Success(T, ArrayList<TomlDiagnostic>)
    | Failure(ArrayList<TomlDiagnostic>)

    public func isSuccess(): Bool {
        match (this) {
            case Success(_, _) => true
            case Failure(_) => false
        }
    }

    public func diagnostics(): ArrayList<TomlDiagnostic> {
        match (this) {
            case Success(_, diagnostics) => diagnostics.clone()
            case Failure(diagnostics) => diagnostics.clone()
        }
    }

    public func getOrThrow(): T {
        match (this) {
            case Success(value, _) => value
            case Failure(diagnostics) => throw TomlException.fromDiagnostics(diagnostics)
        }
    }
}

public open class TomlException <: Exception {
    public let diagnostics: ArrayList<TomlDiagnostic>

    public init(message: String, diagnostics!: Collection<TomlDiagnostic> = ArrayList<TomlDiagnostic>()) {
        super(message)
        this.diagnostics = ArrayList<TomlDiagnostic>(diagnostics)
    }

    public static func fromDiagnostics(diagnostics: Collection<TomlDiagnostic>): TomlException {
        let copy = ArrayList<TomlDiagnostic>(diagnostics)
        if (copy.isEmpty()) { return TomlException("TOML operation failed", diagnostics: copy) }
        TomlException(copy[0].toString(), diagnostics: copy)
    }

    protected open override func getClassName(): String { "TomlException" }
}

/// Converts a UTF-8 byte offset to a one-based scalar line/column pair.
public func tomlPositionAt(source: Array<Byte>, offset: Int64): TomlPosition {
    if (offset < 0 || offset > source.size) {
        throw IllegalArgumentException("byte offset is outside the source")
    }
    var line: Int64 = 1
    var column: Int64 = 1
    var index: Int64 = 0
    while (index < offset) {
        let byte = source[index]
        if (byte == b'\n') {
            line++
            column = 1
            index++
        } else {
            column++
            index += tomlUtf8SequenceLength(source, index)
        }
    }
    TomlPosition(line, column)
}

/// Converts a UTF-8 byte offset to a zero-based UTF-16 editor position.
public func tomlUtf16PositionAt(source: Array<Byte>, offset: Int64): TomlUtf16Position {
    if (offset < 0 || offset > source.size) {
        throw IllegalArgumentException("byte offset is outside the source")
    }
    var line: Int64 = 0
    var character: Int64 = 0
    var index: Int64 = 0
    while (index < offset) {
        if (source[index] == b'\n') {
            line++
            character = 0
            index++
        } else {
            let width = tomlUtf8SequenceLength(source, index)
            character += if (width == 4) { 2 } else { 1 }
            index += width
        }
    }
    TomlUtf16Position(line, character)
}

private func tomlUtf8SequenceLength(source: Array<Byte>, index: Int64): Int64 {
    let first = source[index]
    if (first < 0x80) { return 1 }
    if (first >= 0xC2 && first <= 0xDF && index + 1 < source.size &&
        source[index + 1] >= 0x80 && source[index + 1] <= 0xBF) { return 2 }
    if (first >= 0xE0 && first <= 0xEF && index + 2 < source.size &&
        source[index + 1] >= 0x80 && source[index + 1] <= 0xBF &&
        source[index + 2] >= 0x80 && source[index + 2] <= 0xBF) { return 3 }
    if (first >= 0xF0 && first <= 0xF4 && index + 3 < source.size &&
        source[index + 1] >= 0x80 && source[index + 1] <= 0xBF &&
        source[index + 2] >= 0x80 && source[index + 2] <= 0xBF &&
        source[index + 3] >= 0x80 && source[index + 3] <= 0xBF) { return 4 }
    1
}
