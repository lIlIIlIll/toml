// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*

/// Versioned support surface consumed by generated codecs. Macro packages must
/// target this API instead of compiler internals or a reflection data model.
public class TomlGeneratedSupportV1 {
    public static let abiVersion: Int64 = 1

    public static func missingField<T>(name: String, context: TomlDecodeContext): TomlOutcome<T> {
        tomlCodecFailure<T>("missing_field", "required field '${name}' is missing", context.atKey(name).path)
    }

    public static func success<T>(value: T): TomlOutcome<T> { tomlCodecSuccess<T>(value) }

    public static func failure<T>(
        code: String,
        message: String,
        path: TomlPath
    ): TomlOutcome<T> {
        tomlCodecFailure<T>(code, message, path)
    }

    public static func diagnostic(code: String, message: String, path: TomlPath): TomlDiagnostic {
        TomlDiagnostic(code, TomlSeverity.Error, message, path: Some(path))
    }

    public static func unknownFields(
        table: TomlTable,
        known: Collection<String>,
        context: TomlDecodeContext
    ): ArrayList<TomlDiagnostic> {
        let diagnostics = ArrayList<TomlDiagnostic>()
        let reject = match (context.options.unknownFields) {
            case TomlUnknownFieldPolicy.Reject => true
            case TomlUnknownFieldPolicy.Ignore => false
        }
        if (!reject) { return diagnostics }
        for (key in table.keys()) {
            var recognized = false
            for (candidate in known) {
                if (candidate == key) { recognized = true; break }
            }
            if (!recognized) {
                diagnostics.add(TomlDiagnostic("unknown_field", TomlSeverity.Error,
                    "unknown field '${key}'", path: Some(context.atKey(key).path)))
            }
        }
        diagnostics
    }

    public static func expectTable(
        value: TomlValue,
        context: TomlDecodeContext
    ): TomlOutcome<TomlTable> {
        match (value) {
            case table: TomlTable => tomlCodecSuccess<TomlTable>(table)
            case _ => tomlCodecFailure<TomlTable>("type_mismatch", "expected a TOML table", context.path)
        }
    }

    public static func fieldName(source: String, naming: TomlFieldNaming): String {
        match (naming) {
            case TomlFieldNaming.Exact => source
            case TomlFieldNaming.SnakeCase => tomlGeneratedSeparatedName(source, r'_')
            case TomlFieldNaming.KebabCase => tomlGeneratedSeparatedName(source, r'-')
        }
    }
}

private func tomlGeneratedSeparatedName(source: String, separator: Rune): String {
    let output = StringBuilder()
    var first = true
    for (rune in source.runes()) {
        if (rune >= r'A' && rune <= r'Z') {
            if (!first) { output.append(separator) }
            output.append(Rune(UInt32(rune) + 32))
        } else {
            output.append(rune)
        }
        first = false
    }
    output.toString()
}
