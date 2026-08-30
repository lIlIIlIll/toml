// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*
import std.io.*

/// Immutable, reusable, thread-safe parser configuration.
public class TomlParser {
    public let options: TomlParseOptions

    public init(options!: TomlParseOptions = TomlParseOptions.defaults) {
        this.options = options
    }

    public func parse(text: String): TomlOutcome<TomlTable> {
        parse(tomlCloneStringBytes(text))
    }

    public func parse(bytes: Array<Byte>): TomlOutcome<TomlTable> {
        let parsed = tomlParseInternal(bytes.clone(), options)
        if (parsed.fatal || tomlHasErrors(parsed.diagnostics)) {
            TomlOutcome<TomlTable>.Failure(parsed.diagnostics.clone())
        } else {
            TomlOutcome<TomlTable>.Success(parsed.root, parsed.diagnostics.clone())
        }
    }

    /// Reads to EOF without closing the caller-owned stream.
    public func parse(input: InputStream): TomlOutcome<TomlTable> {
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
                    return TomlOutcome<TomlTable>.Failure(diagnostics)
                }
            }
        } catch (exception: Exception) {
            let diagnostics = ArrayList<TomlDiagnostic>()
            diagnostics.add(TomlDiagnostic("stream_read_error", TomlSeverity.Error,
                "failed to read TOML input stream: ${exception.message}"))
            return TomlOutcome<TomlTable>.Failure(diagnostics)
        }
        parse(bytes.toArray())
    }

    public func parseOrThrow(text: String): TomlTable { parse(text).getOrThrow() }
    public func parseOrThrow(bytes: Array<Byte>): TomlTable { parse(bytes).getOrThrow() }
    public func parseOrThrow(input: InputStream): TomlTable { parse(input).getOrThrow() }
}

public func parseToml(text: String, options!: TomlParseOptions = TomlParseOptions.defaults): TomlOutcome<TomlTable> {
    TomlParser(options: options).parse(text)
}

public func parseToml(bytes: Array<Byte>, options!: TomlParseOptions = TomlParseOptions.defaults): TomlOutcome<TomlTable> {
    TomlParser(options: options).parse(bytes)
}

public func parseToml(input: InputStream, options!: TomlParseOptions = TomlParseOptions.defaults): TomlOutcome<TomlTable> {
    TomlParser(options: options).parse(input)
}

public class Toml {
    public static func parse(text: String, options!: TomlParseOptions = TomlParseOptions.defaults): TomlOutcome<TomlTable> {
        parseToml(text, options: options)
    }

    public static func parse(bytes: Array<Byte>, options!: TomlParseOptions = TomlParseOptions.defaults): TomlOutcome<TomlTable> {
        parseToml(bytes, options: options)
    }

    public static func parse(input: InputStream, options!: TomlParseOptions = TomlParseOptions.defaults): TomlOutcome<TomlTable> {
        parseToml(input, options: options)
    }
}

func tomlParseInternal(bytes: Array<Byte>, options: TomlParseOptions): TomlInternalParseResult {
    TomlParserState(bytes, options).run()
}

func tomlHasErrors(diagnostics: Collection<TomlDiagnostic>): Bool {
    for (diagnostic in diagnostics) {
        match (diagnostic.severity) {
            case TomlSeverity.Error => return true
            case _ => ()
        }
    }
    false
}
