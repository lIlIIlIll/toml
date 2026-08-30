// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*
import std.convert.Formattable
import std.io.*
import std.math.numeric.BigInt

private let TOML_ENCODER_INT64_MIN = BigInt.parse("-9223372036854775808")
private let TOML_ENCODER_INT64_MAX = BigInt.parse("9223372036854775807")

/// Immutable, reusable, thread-safe semantic TOML encoder.
public class TomlEncoder {
    public let options: TomlEncodeOptions

    public init(options!: TomlEncodeOptions = TomlEncodeOptions.defaults) {
        this.options = options
    }

    public func encode(table: TomlTable): TomlOutcome<String> {
        TomlEncodeState(options).encodeDocument(table)
    }

    public func encodeBytes(table: TomlTable): TomlOutcome<Array<Byte>> {
        match (encode(table)) {
            case TomlOutcome<String>.Success(text, diagnostics) =>
                TomlOutcome<Array<Byte>>.Success(tomlCloneStringBytes(text), diagnostics)
            case TomlOutcome<String>.Failure(diagnostics) =>
                TomlOutcome<Array<Byte>>.Failure(diagnostics)
        }
    }

    /// Writes without flushing or closing the caller-owned stream.
    public func encodeTo(table: TomlTable, output: OutputStream): TomlOutcome<Unit> {
        match (encodeBytes(table)) {
            case TomlOutcome<Array<Byte>>.Success(bytes, diagnostics) =>
                try {
                    output.write(bytes)
                    TomlOutcome<Unit>.Success((), diagnostics)
                } catch (exception: Exception) {
                    let failure = diagnostics.clone()
                    failure.add(TomlDiagnostic("stream_write_error", TomlSeverity.Error,
                        "failed to write TOML output stream: ${exception.message}"))
                    TomlOutcome<Unit>.Failure(failure)
                }
            case TomlOutcome<Array<Byte>>.Failure(diagnostics) => TomlOutcome<Unit>.Failure(diagnostics)
        }
    }

    /// Formats a TOML value fragment. Unlike encode(), the root need not be a table.
    public func formatValue(value: TomlValue): TomlOutcome<String> {
        TomlEncodeState(options).encodeFragment(value)
    }
}

public func encodeToml(table: TomlTable, options!: TomlEncodeOptions = TomlEncodeOptions.defaults): TomlOutcome<String> {
    TomlEncoder(options: options).encode(table)
}

public func formatTomlValue(value: TomlValue,
    options!: TomlEncodeOptions = TomlEncodeOptions.defaults): TomlOutcome<String> {
    TomlEncoder(options: options).formatValue(value)
}

extend Toml {
    public static func encode(table: TomlTable,
        options!: TomlEncodeOptions = TomlEncodeOptions.defaults): TomlOutcome<String> {
        encodeToml(table, options: options)
    }
}

private class TomlEncodeState {
    private let options: TomlEncodeOptions
    private let diagnostics = ArrayList<TomlDiagnostic>()
    private let lines = ArrayList<String>()
    private let ancestors = ArrayList<TomlValue>()

    init(options: TomlEncodeOptions) { this.options = options }

    func encodeDocument(root: TomlTable): TomlOutcome<String> {
        writeTable(root, ArrayList<String>(), false, 0)
        if (tomlHasErrors(diagnostics)) { return TomlOutcome<String>.Failure(diagnostics) }
        let newline = newlineText()
        let out = StringBuilder()
        for (position in 0..lines.size) {
            if (position > 0) { out.append(newline) }
            out.append(lines[position])
        }
        if (options.style.finalNewline && !lines.isEmpty()) { out.append(newline) }
        TomlOutcome<String>.Success(out.toString(), diagnostics)
    }

    func encodeFragment(value: TomlValue): TomlOutcome<String> {
        match (renderValue(value, TomlPath(), 0)) {
            case Some(text) =>
                if (tomlHasErrors(diagnostics)) { TomlOutcome<String>.Failure(diagnostics) }
                else { TomlOutcome<String>.Success(text, diagnostics) }
            case None => TomlOutcome<String>.Failure(diagnostics)
        }
    }

    private func newlineText(): String {
        match (options.style.newline) {
            case TomlNewline.Lf => "\n"
            case TomlNewline.CrLf => "\r\n"
        }
    }

    private func addBlankLine(): Unit {
        if (!lines.isEmpty() && !lines[lines.size - 1].isEmpty()) { lines.add("") }
    }

    private func writeTable(table: TomlTable, path: ArrayList<String>, emitHeader: Bool, depth: Int64): Unit {
        if (!enter(table, TomlPath(), depth)) { return }
        try {
            if (emitHeader) { lines.add("[${tomlRenderKeyPath(path)}]") }
            for (key in table.keys()) {
                let value = table[key]
                if (isDirectEntry(value)) {
                    let valuePath = tomlPathFromKeys(path).withKey(key)
                    match (renderValue(value, valuePath, depth + 1)) {
                        case Some(text) => lines.add("${tomlRenderKey(key)} = ${text}")
                        case None => ()
                    }
                }
            }
            for (key in table.keys()) {
                match (table[key]) {
                    case child: TomlTable =>
                        if (!child.isInline) {
                            addBlankLine()
                            let childPath = path.clone(); childPath.add(key)
                            writeTable(child, childPath, true, depth + 1)
                        }
                    case array: TomlArray =>
                        if (array.isArrayOfTables) {
                            let childPath = path.clone(); childPath.add(key)
                            for (item in array.values()) {
                                match (item) {
                                    case child: TomlTable =>
                                        addBlankLine()
                                        lines.add("[[${tomlRenderKeyPath(childPath)}]]")
                                        writeTableBodyAfterHeader(child, childPath, depth + 1)
                                    case _ =>
                                        diagnostic("array_of_tables_type", "array marked as array-of-tables contains a non-table value",
                                            tomlPathFromKeys(childPath))
                                }
                            }
                        }
                    case _ => ()
                }
            }
        } finally { ancestors.remove(at: ancestors.size - 1) }
    }

    private func writeTableBodyAfterHeader(table: TomlTable, path: ArrayList<String>, depth: Int64): Unit {
        if (!enter(table, tomlPathFromKeys(path), depth)) { return }
        try {
            for (key in table.keys()) {
                let value = table[key]
                if (isDirectEntry(value)) {
                    match (renderValue(value, tomlPathFromKeys(path).withKey(key), depth + 1)) {
                        case Some(text) => lines.add("${tomlRenderKey(key)} = ${text}")
                        case None => ()
                    }
                }
            }
            for (key in table.keys()) {
                match (table[key]) {
                    case child: TomlTable =>
                        if (!child.isInline) {
                            addBlankLine()
                            let childPath = path.clone(); childPath.add(key)
                            writeTable(child, childPath, true, depth + 1)
                        }
                    case array: TomlArray =>
                        if (array.isArrayOfTables) {
                            let childPath = path.clone(); childPath.add(key)
                            for (item in array.values()) {
                                match (item) {
                                    case child: TomlTable =>
                                        addBlankLine()
                                        lines.add("[[${tomlRenderKeyPath(childPath)}]]")
                                        writeTableBodyAfterHeader(child, childPath, depth + 1)
                                    case _ => diagnostic("array_of_tables_type",
                                        "array marked as array-of-tables contains a non-table value",
                                        tomlPathFromKeys(childPath))
                                }
                            }
                        }
                    case _ => ()
                }
            }
        } finally { ancestors.remove(at: ancestors.size - 1) }
    }

    private func isDirectEntry(value: TomlValue): Bool {
        match (value) {
            case table: TomlTable => table.isInline
            case array: TomlArray => !array.isArrayOfTables
            case _ => true
        }
    }

    private func enter(value: TomlValue, path: TomlPath, depth: Int64): Bool {
        if (depth > 256) {
            diagnostic("depth_limit", "encoding depth exceeds 256", path)
            return false
        }
        for (ancestor in ancestors) {
            if (refEq(value, ancestor)) {
                diagnostic("cyclic_reference", "cannot encode a cyclic TOML value graph", path)
                return false
            }
        }
        ancestors.add(value)
        true
    }

    private func renderValue(value: TomlValue, path: TomlPath, depth: Int64): Option<String> {
        if (depth > 256) {
            diagnostic("depth_limit", "encoding depth exceeds 256", path)
            return None<String>
        }
        match (value) {
            case item: TomlString => Some(tomlRenderString(item.value))
            case item: TomlInteger =>
                match (options.integerMode) {
                    case TomlIntegerMode.PortableInt64 =>
                        if (item.value < TOML_ENCODER_INT64_MIN || item.value > TOML_ENCODER_INT64_MAX) {
                            diagnostic("integer_out_of_range", "integer is outside the portable Int64 range", path)
                            return None<String>
                        }
                    case TomlIntegerMode.ArbitraryPrecision => ()
                }
                Some(item.value.toString())
            case item: TomlFloat => Some(tomlRenderFloat(item.value))
            case item: TomlBoolean => Some(item.value.toString())
            case item: TomlOffsetDateTime => Some(item.toString())
            case item: TomlLocalDateTime => Some(item.toString())
            case item: TomlLocalDate => Some(item.toString())
            case item: TomlLocalTime => Some(item.toString())
            case array: TomlArray => renderArray(array, path, depth)
            case table: TomlTable => renderInlineTable(table, path, depth)
            case _ =>
                diagnostic("unsupported_value", "unsupported TomlValue implementation", path)
                None<String>
        }
    }

    private func renderArray(array: TomlArray, path: TomlPath, depth: Int64): Option<String> {
        if (array.isArrayOfTables) {
            diagnostic("array_of_tables_fragment", "an array of tables cannot be rendered as a value fragment", path)
            return None<String>
        }
        if (!enter(array, path, depth)) { return None<String> }
        try {
            let rendered = ArrayList<String>()
            for (position in 0..array.size) {
                match (renderValue(array[position], path.withIndex(position), depth + 1)) {
                    case Some(text) => rendered.add(text)
                    case None => return None<String>
                }
            }
            let compact = StringBuilder("[")
            for (position in 0..rendered.size) {
                if (position > 0) { compact.append(", ") }
                compact.append(rendered[position])
            }
            compact.append("]")
            let compactText = compact.toString()
            if (compactText.size <= options.style.maxWidth || rendered.isEmpty()) { return Some(compactText) }
            let expanded = StringBuilder("[")
            expanded.append(newlineText())
            let indent = options.style.indent * (depth + 1)
            for (item in rendered) {
                expanded.append(indent)
                expanded.append(item)
                expanded.append(",")
                expanded.append(newlineText())
            }
            expanded.append(options.style.indent * depth)
            expanded.append("]")
            Some(expanded.toString())
        } finally { ancestors.remove(at: ancestors.size - 1) }
    }

    private func renderInlineTable(table: TomlTable, path: TomlPath, depth: Int64): Option<String> {
        if (!table.isInline) {
            diagnostic("table_fragment", "non-inline table cannot be encoded as a value; encode it as a document table", path)
            return None<String>
        }
        if (!enter(table, path, depth)) { return None<String> }
        try {
            let out = StringBuilder("{")
            let keys = table.keys()
            for (position in 0..keys.size) {
                if (position > 0) { out.append(", ") }
                let key = keys[position]
                out.append(tomlRenderKey(key))
                out.append(" = ")
                match (renderValue(table[key], path.withKey(key), depth + 1)) {
                    case Some(text) => out.append(text)
                    case None => return None<String>
                }
            }
            out.append("}")
            Some(out.toString())
        } finally { ancestors.remove(at: ancestors.size - 1) }
    }

    private func diagnostic(code: String, message: String, path: TomlPath): Unit {
        diagnostics.add(TomlDiagnostic(code, TomlSeverity.Error, message, path: Some(path)))
    }
}

private func tomlPathFromKeys(keys: Collection<String>): TomlPath {
    var path = TomlPath()
    for (key in keys) { path = path.withKey(key) }
    path
}

func tomlRenderKeyPath(keys: Collection<String>): String {
    let out = StringBuilder()
    var first = true
    for (key in keys) {
        if (!first) { out.append(".") }
        out.append(tomlRenderKey(key))
        first = false
    }
    out.toString()
}

func tomlRenderKey(key: String): String {
    if (!key.isEmpty()) {
        var bare = true
        unsafe {
            for (byte in key.rawData()) {
                if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
                    (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-')) {
                    bare = false
                    break
                }
            }
        }
        if (bare) { return key }
    }
    tomlRenderString(key)
}

private func tomlRenderString(value: String): String {
    let out = StringBuilder("\"")
    for (rune in value.runes()) {
        match (rune) {
            case r'\b' => out.append("\\b")
            case r'\t' => out.append("\\t")
            case r'\n' => out.append("\\n")
            case r'\f' => out.append("\\f")
            case r'\r' => out.append("\\r")
            case r'\"' => out.append("\\\"")
            case r'\\' => out.append("\\\\")
            case _ =>
                let codePoint = UInt32(rune)
                if (codePoint < 0x20 || codePoint == 0x7F) {
                    out.append("\\u")
                    out.append(tomlHexFixed(codePoint, 4))
                } else { out.append(rune) }
        }
    }
    out.append("\"")
    out.toString()
}

private func tomlHexFixed(value: UInt32, width: Int64): String {
    let digits = "0123456789ABCDEF"
    let out = StringBuilder()
    for (position in 0..width) {
        let shift = UInt32((width - position - 1) * 4)
        let digit = Int64((value >> shift) & 0xF)
        out.append(Rune(UInt32(unsafe { digits.rawData()[digit] })))
    }
    out.toString()
}

private func tomlRenderFloat(value: Float64): String {
    if (value.isNaN()) { return "nan" }
    if (value.isInf()) { return if (value < 0.0) { "-inf" } else { "inf" } }
    let text = value.format(".17g")
    var hasMarker = false
    unsafe {
        for (byte in text.rawData()) {
            if (byte == b'.' || byte == b'e' || byte == b'E') { hasMarker = true; break }
        }
    }
    if (hasMarker) { text } else { "${text}.0" }
}
