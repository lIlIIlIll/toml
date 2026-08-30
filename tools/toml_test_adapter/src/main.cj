// SPDX-License-Identifier: Apache-2.0
package toml_test_adapter

import std.env.*
import toml.*

private func appendJsonHexNibble(output: StringBuilder, value: UInt32): Unit {
    let digits = "0123456789abcdef"
    let byte = unsafe { digits.rawData()[Int64(value & 0xF)] }
    output.append(Rune(UInt32(byte)))
}

private func appendJsonString(output: StringBuilder, value: String): Unit {
    output.append("\"")
    for (rune in value.runes()) {
        match (rune) {
            case r'\"' => output.append("\\\"")
            case r'\\' => output.append("\\\\")
            case r'\b' => output.append("\\b")
            case r'\f' => output.append("\\f")
            case r'\n' => output.append("\\n")
            case r'\r' => output.append("\\r")
            case r'\t' => output.append("\\t")
            case _ =>
                let codePoint = UInt32(rune)
                if (codePoint < 0x20) {
                    output.append("\\u00")
                    appendJsonHexNibble(output, codePoint >> 4)
                    appendJsonHexNibble(output, codePoint)
                } else {
                    output.append(rune)
                }
        }
    }
    output.append("\"")
}

private func taggedJson(tag: String, text: String): String {
    let output = StringBuilder("{\"type\":")
    appendJsonString(output, tag)
    output.append(",\"value\":")
    appendJsonString(output, text)
    output.append("}")
    output.toString()
}

private func renderTaggedJson(value: TomlValue): String {
    match (value) {
        case table: TomlTable =>
            let output = StringBuilder("{")
            let keys = table.keys()
            for (index in 0..keys.size) {
                if (index > 0) { output.append(",") }
                let key = keys[index]
                appendJsonString(output, key)
                output.append(":")
                output.append(renderTaggedJson(table[key]))
            }
            output.append("}")
            output.toString()
        case array: TomlArray =>
            let output = StringBuilder("[")
            for (index in 0..array.size) {
                if (index > 0) { output.append(",") }
                output.append(renderTaggedJson(array[index]))
            }
            output.append("]")
            output.toString()
        case stringValue: TomlString => taggedJson("string", stringValue.value)
        case integer: TomlInteger => taggedJson("integer", integer.value.toString())
        case number: TomlFloat => taggedJson("float", number.toString())
        case boolean: TomlBoolean => taggedJson("bool", boolean.value.toString())
        case dateTime: TomlOffsetDateTime => taggedJson("datetime", dateTime.toString())
        case dateTime: TomlLocalDateTime => taggedJson("datetime-local", dateTime.toString())
        case date: TomlLocalDate => taggedJson("date-local", date.toString())
        case time: TomlLocalTime => taggedJson("time-local", time.toString())
        case _ => throw IllegalStateException("unsupported TOML value in toml-test adapter")
    }
}

private func adapterOptions(): TomlParseOptions {
    match (getVariable("TOML_VERSION")) {
        case Some("1.0") => TomlParseOptions.strict10
        case _ => TomlParseOptions.strict11
    }
}

main(): Int64 {
    let source = match (getStdIn().readToEnd()) {
        case Some(value) => value
        case None => ""
    }
    match (parseToml(source, options: adapterOptions())) {
        case TomlOutcome<TomlTable>.Success(value, _) =>
            getStdOut().writeln(renderTaggedJson(value))
            0
        case TomlOutcome<TomlTable>.Failure(diagnostics) =>
            for (diagnostic in diagnostics) {
                getStdErr().writeln(diagnostic.toString())
            }
            1
    }
}
