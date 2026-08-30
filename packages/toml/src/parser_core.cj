// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*
import std.convert.Parsable
import std.math.numeric.BigInt
import std.math.numeric.Decimal

enum TomlParsedStatementKind {
    KeyValue | TableHeader | ArrayTableHeader
}

class TomlParsedStatement {
    let kind: TomlParsedStatementKind
    let span: TomlSpan
    let keyStart: Int64
    let keyEnd: Int64
    let valueSpan: Option<TomlSpan>
    let path: ArrayList<String>

    init(
        kind: TomlParsedStatementKind,
        span: TomlSpan,
        parsedKeyStart: Int64,
        parsedKeyEnd: Int64,
        valueSpan: Option<TomlSpan>,
        path: Collection<String>
    ) {
        this.kind = kind
        this.span = span
        this.keyStart = parsedKeyStart
        this.keyEnd = parsedKeyEnd
        this.valueSpan = valueSpan
        this.path = ArrayList<String>(path)
    }
}

class TomlInternalParseResult {
    let root: TomlTable
    let diagnostics: ArrayList<TomlDiagnostic>
    let statements: ArrayList<TomlParsedStatement>
    let fatal: Bool

    init(root: TomlTable, diagnostics: ArrayList<TomlDiagnostic>,
        statements: ArrayList<TomlParsedStatement>, fatal: Bool) {
        this.root = root
        this.diagnostics = diagnostics
        this.statements = statements
        this.fatal = fatal
    }
}

private let TOML_INT64_MIN_BIG = BigInt.parse("-9223372036854775808")
private let TOML_INT64_MAX_BIG = BigInt.parse("9223372036854775807")

class TomlParserState {
    private let source: Array<Byte>
    private let options: TomlParseOptions
    private let diagnostics = ArrayList<TomlDiagnostic>()
    private let statements = ArrayList<TomlParsedStatement>()
    private let root = TomlTable()
    private var current: TomlTable
    private var currentPath = ArrayList<String>()
    private var index: Int64 = 0
    private var tokenCount: Int64 = 0
    private var nodeCount: Int64 = 1
    private var fatal: Bool = false

    init(source: Array<Byte>, options: TomlParseOptions) {
        this.source = source
        this.options = options
        this.current = root
        root.parserDefinitionState = 2
    }

    func run(): TomlInternalParseResult {
        if (source.size > options.limits.maxInputBytes) {
            fatalResource("input_too_large", "input exceeds ${options.limits.maxInputBytes} bytes",
                TomlSpan(0, source.size))
            return result()
        }
        validateUtf8()
        if (fatal) { return result() }
        consumeBom()
        while (!fatal) {
            skipTopTrivia()
            if (atEnd()) { break }
            let before = index
            if (peek() == b'[') { parseHeader() } else { parseKeyValue() }
            finishStatementLine()
            if (index <= before && !atEnd()) { index++ }
        }
        result()
    }

    private func result(): TomlInternalParseResult {
        TomlInternalParseResult(root, diagnostics, statements, fatal)
    }

    private func atEnd(): Bool { index >= source.size }
    private func peek(): Byte { source[index] }
    private func has(offset: Int64): Bool { index + offset < source.size }
    private func byteAt(offset: Int64): Byte { source[index + offset] }

    private func consumeBom(): Unit {
        if (source.size >= 3 && source[0] == 0xEF && source[1] == 0xBB && source[2] == 0xBF) {
            if (!options.allowBom) {
                error("bom_disabled", "UTF-8 BOM is disabled by the parse options", TomlSpan(0, 3))
            }
            index = 3
        }
    }

    private func validateUtf8(): Unit {
        var cursor: Int64 = 0
        while (cursor < source.size) {
            let width = tomlValidUtf8Width(source, cursor)
            if (width == 0) {
                let span = TomlSpan(cursor, cursor + 1)
                match (options.utf8Policy) {
                    case TomlUtf8Policy.Reject =>
                        error("invalid_utf8", "input is not valid UTF-8", span)
                        fatal = true
                        return
                    case TomlUtf8Policy.ReplaceInvalid =>
                        warning("invalid_utf8_replaced", "invalid UTF-8 byte is interpreted as U+FFFD", span)
                        cursor++
                }
            } else {
                cursor += width
            }
        }
    }

    private func countToken(span: TomlSpan): Unit {
        tokenCount++
        if (tokenCount > options.limits.maxTokens) {
            fatalResource("token_limit", "token count exceeds ${options.limits.maxTokens}", span)
        }
    }

    private func countNode(span: TomlSpan): Unit {
        nodeCount++
        if (nodeCount > options.limits.maxNodes) {
            fatalResource("node_limit", "node count exceeds ${options.limits.maxNodes}", span)
        }
    }

    private func fatalResource(code: String, message: String, span: TomlSpan): Unit {
        if (!fatal) { error(code, message, span) }
        fatal = true
    }

    private func addDiagnostic(diagnostic: TomlDiagnostic): Unit {
        if (diagnostics.size >= options.limits.maxDiagnostics) {
            fatal = true
            return
        }
        diagnostics.add(diagnostic)
        if (diagnostics.size == options.limits.maxDiagnostics) { fatal = true }
    }

    private func error(code: String, message: String, span: TomlSpan, path!: Option<TomlPath> = None<TomlPath>): Unit {
        addDiagnostic(TomlDiagnostic(code, TomlSeverity.Error, message,
            primarySpan: Some(span), path: path))
    }

    private func warning(code: String, message: String, span: TomlSpan): Unit {
        addDiagnostic(TomlDiagnostic(code, TomlSeverity.Warning, message, primarySpan: Some(span)))
    }

    private func skipTopTrivia(): Unit {
        while (!atEnd()) {
            if (peek() == b' ' || peek() == b'\t' || peek() == b'\n') {
                index++
                continue
            }
            if (peek() == b'\r') {
                if (has(1) && byteAt(1) == b'\n') { index += 2 }
                else { error("bare_cr", "a carriage return must be followed by a line feed", TomlSpan(index, index + 1)); index++ }
                continue
            }
            if (peek() == b'#') { skipComment(); continue }
            break
        }
    }

    private func skipComment(): Unit {
        while (!atEnd() && peek() != b'\n' && peek() != b'\r') {
            if ((peek() < 0x20 && peek() != b'\t') || peek() == 0x7F) {
                error("control_character", "control characters are not allowed in comments", TomlSpan(index, index + 1))
            }
            index++
        }
    }

    private func skipSpaces(): Unit {
        while (!atEnd() && (peek() == b' ' || peek() == b'\t')) { index++ }
    }

    private func consumeNewline(): Bool {
        if (atEnd()) { return false }
        if (peek() == b'\n') { index++; return true }
        if (peek() == b'\r') {
            if (has(1) && byteAt(1) == b'\n') { index += 2; return true }
            error("bare_cr", "a carriage return must be followed by a line feed", TomlSpan(index, index + 1))
            index++
            return true
        }
        false
    }

    private func skipCollectionTrivia(allowNewlines: Bool, allowComments: Bool): Bool {
        var sawNewline = false
        while (!atEnd()) {
            if (peek() == b' ' || peek() == b'\t') { index++; continue }
            if (peek() == b'#' && allowComments) { skipComment(); continue }
            if ((peek() == b'\n' || peek() == b'\r') && allowNewlines) {
                let _ = consumeNewline()
                sawNewline = true
                continue
            }
            break
        }
        sawNewline
    }

    private func finishStatementLine(): Unit {
        skipSpaces()
        if (!atEnd() && peek() == b'#') { skipComment() }
        if (atEnd()) { return }
        if (peek() == b'\n' || peek() == b'\r') {
            let _ = consumeNewline()
            return
        }
        let start = index
        while (!atEnd() && peek() != b'\n' && peek() != b'\r') { index++ }
        error("trailing_characters", "unexpected characters after a TOML statement", TomlSpan(start, index))
        let _ = consumeNewline()
    }

    private func parseHeader(): Unit {
        let statementStart = index
        index++
        let arrayHeader = !atEnd() && peek() == b'['
        if (arrayHeader) { index++ }
        let keyStart = index
        let path = parseKeyPath(b']')
        let keyEnd = index
        skipSpaces()
        if (atEnd() || peek() != b']') {
            error("unterminated_table_header", "table header is missing a closing bracket",
                TomlSpan(statementStart, index))
            recoverLine()
            return
        }
        index++
        if (arrayHeader) {
            if (atEnd() || peek() != b']') {
                error("unterminated_array_table_header", "array-of-tables header is missing its second closing bracket",
                    TomlSpan(statementStart, index))
                recoverLine()
                return
            }
            index++
        }
        match (path) {
            case Some(segments) =>
                countToken(TomlSpan(statementStart, index))
                if (fatal) { return }
                match (resolveHeader(segments, arrayHeader, TomlSpan(statementStart, index))) {
                    case Some(table) =>
                        current = table
                        currentPath = segments.clone()
                        let kind = if (arrayHeader) { TomlParsedStatementKind.ArrayTableHeader }
                            else { TomlParsedStatementKind.TableHeader }
                        statements.add(TomlParsedStatement(kind, TomlSpan(statementStart, index),
                            keyStart, keyEnd, None<TomlSpan>, segments))
                    case None => ()
                }
            case None => ()
        }
    }

    private func parseKeyValue(): Unit {
        let statementStart = index
        let keyStart = index
        let path = parseKeyPath(b'=')
        let keyEnd = index
        skipSpaces()
        if (atEnd() || peek() != b'=') {
            error("missing_equals", "key/value pair is missing '='", TomlSpan(statementStart, index))
            recoverLine()
            return
        }
        index++
        skipSpaces()
        let valueStart = index
        let value = parseValue(0)
        let valueEnd = index
        match ((path, value)) {
            case (Some(segments), Some(parsedValue)) =>
                countToken(TomlSpan(statementStart, valueEnd))
                if (fatal) { return }
                if (assignDotted(current, segments, parsedValue, TomlSpan(keyStart, keyEnd), false)) {
                    let fullPath = currentPath.clone()
                    fullPath.add(all: segments)
                    statements.add(TomlParsedStatement(TomlParsedStatementKind.KeyValue,
                        TomlSpan(statementStart, valueEnd), keyStart, keyEnd,
                        Some(TomlSpan(valueStart, valueEnd)), fullPath))
                }
            case _ => ()
        }
    }

    private func recoverLine(): Unit {
        while (!atEnd() && peek() != b'\n' && peek() != b'\r') { index++ }
    }

    private func parseKeyPath(terminator: Byte): Option<ArrayList<String>> {
        let result = ArrayList<String>()
        var needSegment = true
        while (!atEnd()) {
            skipSpaces()
            if (peek() == terminator) {
                if (needSegment) {
                    error("empty_key", "a dotted key cannot end with '.'", TomlSpan(index, index + 1))
                    return None<ArrayList<String>>
                }
                return Some(result)
            }
            if (!needSegment) {
                if (peek() != b'.') {
                    error("invalid_key", "expected '.' between key segments", TomlSpan(index, index + 1))
                    return None<ArrayList<String>>
                }
                index++
                needSegment = true
                continue
            }
            let segmentStart = index
            let segment = if (peek() == b'\"') {
                parseBasicString(false)
            } else if (peek() == b'\'') {
                parseLiteralString(false)
            } else {
                parseBareKey()
            }
            match (segment) {
                case Some(value) =>
                    result.add(value)
                    if (result.size > options.limits.maxKeySegments) {
                        fatalResource("key_segment_limit", "key has more than ${options.limits.maxKeySegments} segments",
                            TomlSpan(segmentStart, index))
                        return None<ArrayList<String>>
                    }
                    needSegment = false
                case None => return None<ArrayList<String>>
            }
            skipSpaces()
            if (!atEnd() && peek() == terminator) { return Some(result) }
        }
        error("unterminated_key", "key is not terminated", TomlSpan(index, index))
        None<ArrayList<String>>
    }

    private func parseBareKey(): Option<String> {
        let start = index
        while (!atEnd()) {
            let byte = peek()
            if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
                (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-') {
                index++
            } else { break }
        }
        if (index == start) {
            let end = if (atEnd()) { index } else { index + 1 }
            error("invalid_bare_key", "bare keys may contain only ASCII letters, digits, '_' and '-'",
                TomlSpan(start, end))
            return None<String>
        }
        Some(String.fromUtf8(source[start..index]))
    }

    private func pathFor(segments: Collection<String>): TomlPath {
        var path = TomlPath()
        for (segment in currentPath) { path = path.withKey(segment) }
        for (segment in segments) { path = path.withKey(segment) }
        path
    }

    private func resolveHeader(segments: ArrayList<String>, arrayHeader: Bool,
        span: TomlSpan): Option<TomlTable> {
        if (segments.isEmpty()) {
            error("empty_table_header", "table header must contain a key", span)
            return None<TomlTable>
        }
        var table = root
        for (position in 0..segments.size) {
            let key = segments[position]
            let last = position == segments.size - 1
            if (last) {
                if (arrayHeader) {
                    match (table.get(key)) {
                        case None =>
                            let array = TomlArray()
                            array.parserArrayOfTables = true
                            let element = TomlTable()
                            element.parserDefinitionState = 5
                            array.add(element)
                            table.put(key, array)
                            countNode(span); countNode(span)
                            return Some(element)
                        case Some(array: TomlArray) =>
                            if (!array.parserArrayOfTables) {
                                error("table_conflict", "key '${key}' is an array value, not an array of tables",
                                    span, path: Some(pathFor(segments)))
                                return None<TomlTable>
                            }
                            let element = TomlTable()
                            element.parserDefinitionState = 5
                            array.add(element)
                            countNode(span)
                            return Some(element)
                        case Some(_) =>
                            error("table_conflict", "key '${key}' is already defined and cannot become an array of tables",
                                span, path: Some(pathFor(segments)))
                            return None<TomlTable>
                    }
                }
                match (table.get(key)) {
                    case None =>
                        let child = TomlTable()
                        child.parserDefinitionState = 2
                        table.put(key, child)
                        countNode(span)
                        return Some(child)
                    case Some(child: TomlTable) =>
                        if (child.parserDefinitionState == 1) {
                            child.parserDefinitionState = 2
                            return Some(child)
                        }
                        error("duplicate_table", "table '${key}' is already defined", span,
                            path: Some(pathFor(segments)))
                        return None<TomlTable>
                    case Some(_) =>
                        error("table_conflict", "key '${key}' is already defined as a non-table value", span,
                            path: Some(pathFor(segments)))
                        return None<TomlTable>
                }
            }

            match (table.get(key)) {
                case None =>
                    let child = TomlTable()
                    child.parserDefinitionState = 1
                    table.put(key, child)
                    countNode(span)
                    table = child
                case Some(child: TomlTable) =>
                    if (child.parserDefinitionState == 4) {
                        error("inline_table_sealed", "inline table '${key}' cannot be extended", span,
                            path: Some(pathFor(segments)))
                        return None<TomlTable>
                    }
                    table = child
                case Some(array: TomlArray) =>
                    if (!array.parserArrayOfTables || array.size == 0) {
                        error("table_conflict", "key '${key}' is not a table", span,
                            path: Some(pathFor(segments)))
                        return None<TomlTable>
                    }
                    match (array[array.size - 1]) {
                        case child: TomlTable => table = child
                        case _ =>
                            error("table_conflict", "array-of-tables '${key}' has an invalid element", span)
                            return None<TomlTable>
                    }
                case Some(_) =>
                    error("table_conflict", "key '${key}' is already defined as a value", span,
                        path: Some(pathFor(segments)))
                    return None<TomlTable>
            }
        }
        None<TomlTable>
    }

    private func assignDotted(table: TomlTable, segments: ArrayList<String>, value: TomlValue,
        span: TomlSpan, inlineContext: Bool): Bool {
        if (segments.isEmpty()) { return false }
        var owner = table
        for (position in 0..segments.size - 1) {
            let key = segments[position]
            match (owner.get(key)) {
                case None =>
                    let child = TomlTable(inline: inlineContext)
                    child.parserDefinitionState = 3
                    owner.put(key, child)
                    countNode(span)
                    owner = child
                case Some(child: TomlTable) =>
                    if (child.parserDefinitionState == 2 || child.parserDefinitionState == 4) {
                        error("dotted_key_redefines_table",
                            "dotted key cannot extend previously defined table '${key}'", span,
                            path: Some(pathFor(segments)))
                        return false
                    }
                    owner = child
                case Some(_) =>
                    error("dotted_key_conflict", "dotted key segment '${key}' is already a value", span,
                        path: Some(pathFor(segments)))
                    return false
            }
        }
        let leaf = segments[segments.size - 1]
        if (owner.contains(leaf)) {
            error("duplicate_key", "key '${leaf}' is already defined", span,
                path: Some(pathFor(segments)))
            return false
        }
        owner.put(leaf, value)
        true
    }

    private func parseValue(depth: Int64): Option<TomlValue> {
        if (depth > options.limits.maxDepth) {
            fatalResource("depth_limit", "value nesting exceeds ${options.limits.maxDepth}",
                TomlSpan(index, if (atEnd()) { index } else { index + 1 }))
            return None<TomlValue>
        }
        if (atEnd()) {
            error("missing_value", "expected a TOML value", TomlSpan(index, index))
            return None<TomlValue>
        }
        let start = index
        let parsed: Option<TomlValue> = match (peek()) {
            case b'\"' =>
                match (parseBasicString(true)) {
                    case Some(value) => Some(TomlString(value))
                    case None => None<TomlValue>
                }
            case b'\'' =>
                match (parseLiteralString(true)) {
                    case Some(value) => Some(TomlString(value))
                    case None => None<TomlValue>
                }
            case b'[' => parseArray(depth + 1)
            case b'{' => parseInlineTable(depth + 1)
            case _ => parseBareValue()
        }
        if (let Some(_) <- parsed) { countNode(TomlSpan(start, index)) }
        parsed
    }

    // String, array, inline-table, numeric, and temporal parsing follow below.

    private func parseBasicString(allowMultiline: Bool): Option<String> {
        let start = index
        index++
        let multiline = has(1) && peek() == b'\"' && byteAt(1) == b'\"'
        if (multiline) {
            if (!allowMultiline) {
                error("multiline_key", "multiline strings are not allowed as keys", TomlSpan(start, index + 2))
                return None<String>
            }
            index += 2
            let _ = consumeNewline()
        }
        let out = StringBuilder()
        while (!atEnd()) {
            if (peek() == b'\"') {
                if (!multiline) { index++; return Some(out.toString()) }
                var quotes: Int64 = 0
                while (index + quotes < source.size && source[index + quotes] == b'\"') { quotes++ }
                if (quotes >= 3) {
                    if (quotes > 5) {
                        error("invalid_quote_run", "a multiline basic string may end with at most five quotes",
                            TomlSpan(index, index + quotes))
                    }
                    var literalQuotes = quotes - 3
                    if (literalQuotes > 2) { literalQuotes = 2 }
                    for (_ in 0..literalQuotes) { out.append(r'\"') }
                    index += quotes
                    return Some(out.toString())
                }
                for (_ in 0..quotes) { out.append(r'\"') }
                index += quotes
                continue
            }
            if (peek() == b'\\') {
                if (!parseEscape(out, multiline)) { return None<String> }
                continue
            }
            if (peek() == b'\n' || peek() == b'\r') {
                if (!multiline) {
                    error("newline_in_string", "a single-line basic string cannot contain a newline",
                        TomlSpan(start, index))
                    return None<String>
                }
                if (peek() == b'\r' && (!has(1) || byteAt(1) != b'\n')) {
                    error("bare_cr", "a carriage return must be followed by a line feed", TomlSpan(index, index + 1))
                    index++
                } else {
                    let _ = consumeNewline()
                }
                out.append(r'\n')
                continue
            }
            if (peek() < 0x20 || peek() == 0x7F) {
                if (peek() == b'\t') { out.append(r'\t'); index++; continue }
                error("control_character", "unescaped control character in basic string",
                    TomlSpan(index, index + 1))
                index++
                continue
            }
            appendSourceRune(out)
        }
        error("unterminated_string", "basic string is not terminated", TomlSpan(start, index))
        None<String>
    }

    private func parseEscape(out: StringBuilder, multiline: Bool): Bool {
        let slash = index
        index++
        if (atEnd()) {
            error("unterminated_escape", "escape sequence is not complete", TomlSpan(slash, index))
            return false
        }
        if (multiline) {
            var look = index
            while (look < source.size && (source[look] == b' ' || source[look] == b'\t')) { look++ }
            if (look < source.size && (source[look] == b'\n' || source[look] == b'\r')) {
                index = look
                let _ = consumeNewline()
                while (!atEnd()) {
                    if (peek() == b' ' || peek() == b'\t') { index++; continue }
                    if (peek() == b'\n' || peek() == b'\r') { let _ = consumeNewline(); continue }
                    break
                }
                return true
            }
        }
        let marker = peek()
        index++
        match (marker) {
            case b'b' => out.append(r'\b')
            case b't' => out.append(r'\t')
            case b'n' => out.append(r'\n')
            case b'f' => out.append(r'\f')
            case b'r' => out.append(r'\r')
            case b'\"' => out.append(r'\"')
            case b'\\' => out.append(r'\\')
            case b'e' =>
                if (!isVersion11()) {
                    error("escape_requires_toml_1_1", "\\e escape requires TOML 1.1", TomlSpan(slash, index))
                    return false
                }
                out.append(Rune(0x1B))
            case b'x' =>
                if (!isVersion11()) {
                    error("escape_requires_toml_1_1", "\\x escape requires TOML 1.1", TomlSpan(slash, index))
                    return false
                }
                return parseFixedUnicodeEscape(out, 2, slash)
            case b'u' =>
                if (!atEnd() && peek() == b'{') {
                    if (!isVersion11()) {
                        error("escape_requires_toml_1_1", "\\u{...} escape requires TOML 1.1",
                            TomlSpan(slash, index + 1))
                        return false
                    }
                    return parseBracedUnicodeEscape(out, slash)
                }
                return parseFixedUnicodeEscape(out, 4, slash)
            case b'U' => return parseFixedUnicodeEscape(out, 8, slash)
            case _ =>
                error("invalid_escape", "unknown basic-string escape", TomlSpan(slash, index))
                return false
        }
        true
    }

    private func parseFixedUnicodeEscape(out: StringBuilder, digits: Int64, slash: Int64): Bool {
        if (index + digits > source.size) {
            error("unterminated_escape", "Unicode escape has too few hexadecimal digits", TomlSpan(slash, source.size))
            index = source.size
            return false
        }
        var value: UInt32 = 0
        for (_ in 0..digits) {
            let digit = tomlHexDigit(peek())
            if (digit < 0) {
                error("invalid_unicode_escape", "Unicode escape contains a non-hexadecimal digit",
                    TomlSpan(index, index + 1))
                return false
            }
            value = value * 16 + UInt32(digit)
            index++
        }
        if (!tomlAppendCodePoint(out, value)) {
            error("invalid_unicode_scalar", "Unicode escape is not a Unicode scalar value", TomlSpan(slash, index))
            return false
        }
        true
    }

    private func parseBracedUnicodeEscape(out: StringBuilder, slash: Int64): Bool {
        index++
        var value: UInt32 = 0
        var digits: Int64 = 0
        while (!atEnd() && peek() != b'}') {
            let digit = tomlHexDigit(peek())
            if (digit < 0 || digits >= 6) {
                error("invalid_unicode_escape", "braced Unicode escape must contain 1 to 6 hexadecimal digits",
                    TomlSpan(slash, index + 1))
                return false
            }
            value = value * 16 + UInt32(digit)
            digits++
            index++
        }
        if (atEnd() || digits == 0) {
            error("unterminated_escape", "braced Unicode escape is not terminated", TomlSpan(slash, index))
            return false
        }
        index++
        if (!tomlAppendCodePoint(out, value)) {
            error("invalid_unicode_scalar", "Unicode escape is not a Unicode scalar value", TomlSpan(slash, index))
            return false
        }
        true
    }

    private func parseLiteralString(allowMultiline: Bool): Option<String> {
        let start = index
        index++
        let multiline = has(1) && peek() == b'\'' && byteAt(1) == b'\''
        if (multiline) {
            if (!allowMultiline) {
                error("multiline_key", "multiline strings are not allowed as keys", TomlSpan(start, index + 2))
                return None<String>
            }
            index += 2
            let _ = consumeNewline()
        }
        let out = StringBuilder()
        while (!atEnd()) {
            if (peek() == b'\'') {
                if (!multiline) { index++; return Some(out.toString()) }
                var quotes: Int64 = 0
                while (index + quotes < source.size && source[index + quotes] == b'\'') { quotes++ }
                if (quotes >= 3) {
                    if (quotes > 5) {
                        error("invalid_quote_run", "a multiline literal string may end with at most five quotes",
                            TomlSpan(index, index + quotes))
                    }
                    var literalQuotes = quotes - 3
                    if (literalQuotes > 2) { literalQuotes = 2 }
                    for (_ in 0..literalQuotes) { out.append(r'\'') }
                    index += quotes
                    return Some(out.toString())
                }
                for (_ in 0..quotes) { out.append(r'\'') }
                index += quotes
                continue
            }
            if (peek() == b'\n' || peek() == b'\r') {
                if (!multiline) {
                    error("newline_in_string", "a single-line literal string cannot contain a newline",
                        TomlSpan(start, index))
                    return None<String>
                }
                if (peek() == b'\r' && (!has(1) || byteAt(1) != b'\n')) {
                    error("bare_cr", "a carriage return must be followed by a line feed", TomlSpan(index, index + 1))
                    index++
                } else { let _ = consumeNewline() }
                out.append(r'\n')
                continue
            }
            if (peek() < 0x20 || peek() == 0x7F) {
                if (peek() == b'\t') { out.append(r'\t'); index++; continue }
                error("control_character", "control character in literal string", TomlSpan(index, index + 1))
                index++
                continue
            }
            appendSourceRune(out)
        }
        error("unterminated_string", "literal string is not terminated", TomlSpan(start, index))
        None<String>
    }

    private func appendSourceRune(out: StringBuilder): Unit {
        let width = tomlValidUtf8Width(source, index)
        if (width == 0) {
            out.append(r'\u{FFFD}')
            index++
        } else {
            out.append(Rune(tomlDecodeCodePoint(source, index, width)))
            index += width
        }
    }

    private func isVersion11(): Bool {
        match (options.version) {
            case TomlVersion.V1_1 => true
            case TomlVersion.V1_0 => false
        }
    }

    private func parseArray(depth: Int64): Option<TomlValue> {
        let start = index
        index++
        let array = TomlArray()
        let _ = skipCollectionTrivia(true, true)
        if (!atEnd() && peek() == b']') { index++; return Some(array) }
        while (!atEnd() && !fatal) {
            let before = index
            match (parseValue(depth)) {
                case Some(value) => array.add(value)
                case None => recoverCollectionElement(b']')
            }
            let _ = skipCollectionTrivia(true, true)
            if (atEnd()) { break }
            if (peek() == b']') { index++; return Some(array) }
            if (peek() != b',') {
                error("missing_array_comma", "array elements must be separated by ','",
                    TomlSpan(index, index + 1))
                recoverCollectionElement(b']')
                if (!atEnd() && peek() == b']') { index++; return Some(array) }
            } else {
                index++
                let _ = skipCollectionTrivia(true, true)
                if (!atEnd() && peek() == b']') { index++; return Some(array) }
            }
            if (index <= before && !atEnd()) { index++ }
        }
        error("unterminated_array", "array is missing a closing ']'", TomlSpan(start, index))
        None<TomlValue>
    }

    private func parseInlineTable(depth: Int64): Option<TomlValue> {
        let start = index
        index++
        let table = TomlTable(inline: true)
        table.parserDefinitionState = 4
        let allowMultiline = isVersion11()
        let _ = skipCollectionTrivia(allowMultiline, allowMultiline)
        if (!atEnd() && peek() == b'}') { index++; return Some(table) }
        while (!atEnd() && !fatal) {
            let entryStart = index
            let path = parseKeyPath(b'=')
            skipSpaces()
            if (atEnd() || peek() != b'=') {
                error("missing_equals", "inline-table entry is missing '='", TomlSpan(entryStart, index))
                recoverCollectionElement(b'}')
            } else {
                index++
                skipSpaces()
                let value = parseValue(depth)
                match ((path, value)) {
                    case (Some(segments), Some(parsedValue)) =>
                        let _ = assignDotted(table, segments, parsedValue, TomlSpan(entryStart, index), true)
                    case _ => ()
                }
            }
            let sawNewline = skipCollectionTrivia(allowMultiline, allowMultiline)
            if (sawNewline && !allowMultiline) {
                error("multiline_inline_table", "newlines in inline tables require TOML 1.1",
                    TomlSpan(entryStart, index))
            }
            if (atEnd()) { break }
            if (peek() == b'}') { index++; return Some(table) }
            if (peek() != b',') {
                error("missing_inline_table_comma", "inline-table entries must be separated by ','",
                    TomlSpan(index, index + 1))
                recoverCollectionElement(b'}')
                if (!atEnd() && peek() == b'}') { index++; return Some(table) }
            } else {
                let comma = index
                index++
                let _ = skipCollectionTrivia(allowMultiline, allowMultiline)
                if (!atEnd() && peek() == b'}') {
                    if (!allowMultiline) {
                        error("inline_table_trailing_comma", "trailing comma in an inline table requires TOML 1.1",
                            TomlSpan(comma, comma + 1))
                    }
                    index++
                    return Some(table)
                }
            }
        }
        error("unterminated_inline_table", "inline table is missing a closing '}'", TomlSpan(start, index))
        None<TomlValue>
    }

    private func recoverCollectionElement(closing: Byte): Unit {
        var nestedSquare: Int64 = 0
        var nestedCurly: Int64 = 0
        while (!atEnd()) {
            if (peek() == b'[') { nestedSquare++; index++; continue }
            if (peek() == b'{' ) { nestedCurly++; index++; continue }
            if (peek() == b']') {
                if (nestedSquare == 0 && nestedCurly == 0 && closing == b']') { return }
                if (nestedSquare > 0) { nestedSquare-- }
                index++
                continue
            }
            if (peek() == b'}') {
                if (nestedSquare == 0 && nestedCurly == 0 && closing == b'}') { return }
                if (nestedCurly > 0) { nestedCurly-- }
                index++
                continue
            }
            if (peek() == b',' && nestedSquare == 0 && nestedCurly == 0) { return }
            if (peek() == b'\n' && nestedSquare == 0 && nestedCurly == 0) { return }
            index++
        }
    }

    private func parseBareValue(): Option<TomlValue> {
        let start = index
        while (!atEnd() && !isBareValueDelimiter(peek())) { index++ }
        // TOML permits one space between the date and time components.
        if (index - start == 10 && !atEnd() && peek() == b' ' && looksLikeDate(start, index) &&
            index + 1 < source.size && tomlIsAsciiDigit(source[index + 1])) {
            index++
            while (!atEnd() && !isBareValueDelimiter(peek())) { index++ }
        }
        if (index == start) {
            let end = if (atEnd()) { index } else { index + 1 }
            error("missing_value", "expected a TOML value", TomlSpan(start, end))
            return None<TomlValue>
        }
        let token = tomlDecodeUtf8(source, start, index,
            match (options.utf8Policy) { case TomlUtf8Policy.ReplaceInvalid => true; case _ => false })
        if (token == "true") { return Some(TomlBoolean(true)) }
        if (token == "false") { return Some(TomlBoolean(false)) }

        let temporal = parseTemporalToken(token, TomlSpan(start, index))
        if (temporal[0]) { return temporal[1] }

        if (tomlTokenLooksFloat(token)) { return parseFloatToken(token, TomlSpan(start, index)) }
        parseIntegerToken(token, TomlSpan(start, index))
    }

    private func isBareValueDelimiter(byte: Byte): Bool {
        byte == b' ' || byte == b'\t' || byte == b'\n' || byte == b'\r' ||
            byte == b',' || byte == b']' || byte == b'}' || byte == b'#'
    }

    private func looksLikeDate(start: Int64, end: Int64): Bool {
        end - start == 10 && source[start + 4] == b'-' && source[start + 7] == b'-'
    }

    private func parseIntegerToken(token: String, span: TomlSpan): Option<TomlValue> {
        let raw = unsafe { token.rawData() }
        var cursor: Int64 = 0
        var sign: Byte = b'+'
        var hasSign = false
        if (cursor < raw.size && (raw[cursor] == b'+' || raw[cursor] == b'-')) {
            sign = raw[cursor]
            hasSign = true
            cursor++
        }
        if (cursor >= raw.size) {
            error("invalid_integer", "integer has no digits", span)
            return None<TomlValue>
        }
        var radix: Int64 = 10
        if (cursor + 1 < raw.size && raw[cursor] == b'0') {
            match (raw[cursor + 1]) {
                case b'x' => radix = 16; cursor += 2
                case b'o' => radix = 8; cursor += 2
                case b'b' => radix = 2; cursor += 2
                case _ => ()
            }
        }
        if (cursor >= raw.size) {
            error("invalid_integer", "base-prefixed integer has no digits", span)
            return None<TomlValue>
        }
        if (radix != 10 && hasSign) {
            error("signed_base_integer", "base-prefixed integers cannot have a sign", span)
            return None<TomlValue>
        }
        let cleaned = StringBuilder()
        if (sign == b'-') { cleaned.append("-") }
        else if (sign == b'+') { cleaned.append("+") }
        var digitCount: Int64 = 0
        var firstDigit: Byte = 0
        var previousDigit = false
        for (position in cursor..raw.size) {
            let byte = raw[position]
            if (byte == b'_') {
                let nextIsDigit = position + 1 < raw.size && tomlDigitForRadix(raw[position + 1], radix) >= 0
                if (!previousDigit || !nextIsDigit) {
                    error("invalid_integer_underscore", "integer underscores must separate two digits", span)
                    return None<TomlValue>
                }
                previousDigit = false
                continue
            }
            let digit = tomlDigitForRadix(byte, radix)
            if (digit < 0) {
                error("invalid_integer", "integer contains a digit that is invalid for base ${radix}", span)
                return None<TomlValue>
            }
            if (digitCount == 0) { firstDigit = byte }
            cleaned.append(Rune(UInt32(byte)))
            digitCount++
            previousDigit = true
        }
        if (digitCount == 0 || !previousDigit) {
            error("invalid_integer", "integer has no final digit", span)
            return None<TomlValue>
        }
        if (radix == 10 && digitCount > 1 && firstDigit == b'0') {
            error("leading_zero", "decimal integers cannot contain leading zeroes", span)
            return None<TomlValue>
        }
        try {
            let value = BigInt.parse(cleaned.toString(), radix: radix)
            match (options.integerMode) {
                case TomlIntegerMode.PortableInt64 =>
                    if (value < TOML_INT64_MIN_BIG || value > TOML_INT64_MAX_BIG) {
                        error("integer_out_of_range", "integer is outside the portable Int64 range", span)
                        return None<TomlValue>
                    }
                case TomlIntegerMode.ArbitraryPrecision => ()
            }
            Some(TomlInteger(value))
        } catch (_: Exception) {
            error("invalid_integer", "integer cannot be parsed", span)
            None<TomlValue>
        }
    }

    private func parseFloatToken(token: String, span: TomlSpan): Option<TomlValue> {
        match (token) {
            case "inf" | "+inf" => return Some(TomlFloat(Float64.Inf))
            case "-inf" => return Some(TomlFloat(-Float64.Inf))
            case "nan" | "+nan" | "-nan" => return Some(TomlFloat(Float64.NaN))
            case _ => ()
        }
        let withoutUnderscores = tomlCleanFloatUnderscores(token)
        let cleaned = match (withoutUnderscores) {
            case Some(value) => value
            case None =>
                error("invalid_float_underscore", "float underscores must separate two decimal digits", span)
                return None<TomlValue>
        }
        if (!tomlValidFloatSyntax(cleaned)) {
            error("invalid_float", "invalid TOML floating-point literal", span)
            return None<TomlValue>
        }
        try {
            let value = Decimal.parse(cleaned).toFloat64()
            if (value.isInf()) {
                error("invalid_float", "floating-point value is outside the Float64 range", span)
                return None<TomlValue>
            }
            Some(TomlFloat(value))
        } catch (_: Exception) {
            error("invalid_float", "floating-point value cannot be represented as Float64", span)
            None<TomlValue>
        }
    }

    private func parseTemporalToken(token: String, span: TomlSpan): (Bool, Option<TomlValue>) {
        let raw = unsafe { token.rawData() }
        let dateCandidate = raw.size >= 5 && raw[4] == b'-'
        let timeCandidate = raw.size >= 3 && raw[2] == b':'
        if (!dateCandidate && !timeCandidate) { return (false, None<TomlValue>) }

        if (dateCandidate) {
            if (raw.size < 10 || raw[4] != b'-' || raw[7] != b'-') {
                error("invalid_datetime", "invalid TOML date or date-time literal", span)
                return (true, None<TomlValue>)
            }
            let date = parseDatePart(raw, 0, 10, span)
            if (raw.size == 10) {
                return match (date) {
                    case Some(value) => (true, Some(value))
                    case None => (true, None<TomlValue>)
                }
            }
            let separator = raw[10]
            if (separator != b'T' && separator != b't' && separator != b' ') {
                error("invalid_datetime_separator", "date and time must be separated by 'T', 't', or one space", span)
                return (true, None<TomlValue>)
            }
            var timeEnd = raw.size
            var offsetMinutes: Option<Int64> = None<Int64>
            if (raw[raw.size - 1] == b'Z' || raw[raw.size - 1] == b'z') {
                timeEnd--
                offsetMinutes = Some(0)
            } else {
                var offsetStart: Int64 = -1
                for (position in 11..raw.size) {
                    if ((raw[position] == b'+' || raw[position] == b'-') && position >= 16) {
                        offsetStart = position
                    }
                }
                if (offsetStart >= 0) {
                    timeEnd = offsetStart
                    if (raw.size - offsetStart != 6 || raw[offsetStart + 3] != b':') {
                        error("invalid_datetime_offset", "UTC offset must have the form +HH:MM or -HH:MM", span)
                        return (true, None<TomlValue>)
                    }
                    match ((tomlTwoDecimalDigits(raw, offsetStart + 1),
                        tomlTwoDecimalDigits(raw, offsetStart + 4))) {
                        case (Some(hours), Some(minutes)) =>
                            if (hours > 23 || minutes > 59) {
                                error("invalid_datetime_offset", "UTC offset is outside the supported range", span)
                                return (true, None<TomlValue>)
                            }
                            let magnitude = hours * 60 + minutes
                            offsetMinutes = Some(if (raw[offsetStart] == b'-') { -magnitude } else { magnitude })
                        case _ =>
                            error("invalid_datetime_offset", "UTC offset contains a non-decimal digit", span)
                            return (true, None<TomlValue>)
                    }
                }
            }
            let time = parseTimePart(raw, 11, timeEnd, span)
            match ((date, time)) {
                case (Some(parsedDate), Some(parsedTime)) =>
                    let local = TomlLocalDateTime(parsedDate, parsedTime)
                    match (offsetMinutes) {
                        case Some(offset) => (true, Some(TomlOffsetDateTime(local, offset)))
                        case None => (true, Some(local))
                    }
                case _ => (true, None<TomlValue>)
            }
        } else {
            match (parseTimePart(raw, 0, raw.size, span)) {
                case Some(value) => (true, Some(value))
                case None => (true, None<TomlValue>)
            }
        }
    }

    private func parseDatePart(raw: Array<Byte>, start: Int64, end: Int64,
        span: TomlSpan): Option<TomlLocalDate> {
        if (end - start != 10 || raw[start + 4] != b'-' || raw[start + 7] != b'-') {
            error("invalid_date", "date must have the form YYYY-MM-DD", span)
            return None<TomlLocalDate>
        }
        match ((tomlFourDecimalDigits(raw, start), tomlTwoDecimalDigits(raw, start + 5),
            tomlTwoDecimalDigits(raw, start + 8))) {
            case (Some(year), Some(month), Some(day)) =>
                try {
                    Some(TomlLocalDate(year, month, day))
                } catch (_: Exception) {
                    error("invalid_date", "date contains an out-of-range component", span)
                    None<TomlLocalDate>
                }
            case _ =>
                error("invalid_date", "date contains a non-decimal digit", span)
                None<TomlLocalDate>
        }
    }

    private func parseTimePart(raw: Array<Byte>, start: Int64, end: Int64,
        span: TomlSpan): Option<TomlLocalTime> {
        if (end - start < 5 || raw[start + 2] != b':') {
            error("invalid_time", "time must begin with HH:MM", span)
            return None<TomlLocalTime>
        }
        let hour = tomlTwoDecimalDigits(raw, start)
        let minute = tomlTwoDecimalDigits(raw, start + 3)
        var second: Int64 = 0
        var fraction = ""
        var cursor = start + 5
        if (cursor < end && raw[cursor] == b':') {
            if (cursor + 3 > end) {
                error("invalid_time", "seconds must contain exactly two digits", span)
                return None<TomlLocalTime>
            }
            match (tomlTwoDecimalDigits(raw, cursor + 1)) {
                case Some(value) => second = value
                case None =>
                    error("invalid_time", "seconds contain a non-decimal digit", span)
                    return None<TomlLocalTime>
            }
            cursor += 3
            if (cursor < end && raw[cursor] == b'.') {
                cursor++
                let fractionStart = cursor
                while (cursor < end && tomlIsAsciiDigit(raw[cursor])) { cursor++ }
                if (cursor == fractionStart) {
                    error("invalid_time_fraction", "fractional seconds require at least one digit", span)
                    return None<TomlLocalTime>
                }
                fraction = String.fromUtf8(raw[fractionStart..cursor])
            }
        } else if (!isVersion11()) {
            error("time_seconds_required", "TOML 1.0 requires the seconds component", span)
            return None<TomlLocalTime>
        }
        if (cursor != end) {
            error("invalid_time", "unexpected characters in time literal", span)
            return None<TomlLocalTime>
        }
        match ((hour, minute)) {
            case (Some(h), Some(m)) =>
                try {
                    Some(TomlLocalTime(h, m, second: second, fraction: fraction))
                } catch (_: Exception) {
                    error("invalid_time", "time contains an out-of-range component", span)
                    None<TomlLocalTime>
                }
            case _ =>
                error("invalid_time", "time contains a non-decimal digit", span)
                None<TomlLocalTime>
        }
    }
}

private func tomlDigitForRadix(byte: Byte, radix: Int64): Int64 {
    let digit = if (byte >= b'0' && byte <= b'9') {
        Int64(byte - b'0')
    } else if (byte >= b'a' && byte <= b'f') {
        Int64(byte - b'a') + 10
    } else if (byte >= b'A' && byte <= b'F') {
        Int64(byte - b'A') + 10
    } else { -1 }
    if (digit >= 0 && digit < radix) { digit } else { -1 }
}

private func tomlTokenLooksFloat(token: String): Bool {
    if (token == "inf" || token == "+inf" || token == "-inf" ||
        token == "nan" || token == "+nan" || token == "-nan") { return true }
    unsafe {
        let raw = token.rawData()
        var cursor: Int64 = 0
        if (cursor < raw.size && (raw[cursor] == b'+' || raw[cursor] == b'-')) { cursor++ }
        if (cursor + 1 < raw.size && raw[cursor] == b'0' &&
            (raw[cursor + 1] == b'x' || raw[cursor + 1] == b'o' || raw[cursor + 1] == b'b')) {
            return false
        }
        for (byte in raw) {
            if (byte == b'.' || byte == b'e' || byte == b'E') { return true }
        }
    }
    false
}

private func tomlCleanFloatUnderscores(token: String): Option<String> {
    let raw = unsafe { token.rawData() }
    let out = StringBuilder()
    for (position in 0..raw.size) {
        let byte = raw[position]
        if (byte == b'_') {
            if (position == 0 || position + 1 >= raw.size ||
                !tomlIsAsciiDigit(raw[position - 1]) || !tomlIsAsciiDigit(raw[position + 1])) {
                return None<String>
            }
        } else {
            out.append(Rune(UInt32(byte)))
        }
    }
    Some(out.toString())
}

private func tomlValidFloatSyntax(value: String): Bool {
    let raw = unsafe { value.rawData() }
    if (raw.isEmpty()) { return false }
    var cursor: Int64 = 0
    if (raw[cursor] == b'+' || raw[cursor] == b'-') {
        cursor++
        if (cursor >= raw.size) { return false }
    }
    let integerStart = cursor
    while (cursor < raw.size && tomlIsAsciiDigit(raw[cursor])) { cursor++ }
    let integerDigits = cursor - integerStart
    if (integerDigits == 0) { return false }
    if (integerDigits > 1 && raw[integerStart] == b'0') { return false }
    var hasFraction = false
    var hasExponent = false
    if (cursor < raw.size && raw[cursor] == b'.') {
        hasFraction = true
        cursor++
        let fractionStart = cursor
        while (cursor < raw.size && tomlIsAsciiDigit(raw[cursor])) { cursor++ }
        if (cursor == fractionStart) { return false }
    }
    if (cursor < raw.size && (raw[cursor] == b'e' || raw[cursor] == b'E')) {
        hasExponent = true
        cursor++
        if (cursor < raw.size && (raw[cursor] == b'+' || raw[cursor] == b'-')) { cursor++ }
        let exponentStart = cursor
        while (cursor < raw.size && tomlIsAsciiDigit(raw[cursor])) { cursor++ }
        if (cursor == exponentStart) { return false }
    }
    cursor == raw.size && (hasFraction || hasExponent)
}

private func tomlTwoDecimalDigits(raw: Array<Byte>, start: Int64): Option<Int64> {
    if (start < 0 || start + 2 > raw.size || !tomlIsAsciiDigit(raw[start]) ||
        !tomlIsAsciiDigit(raw[start + 1])) { return None<Int64> }
    Some(Int64(raw[start] - b'0') * 10 + Int64(raw[start + 1] - b'0'))
}

private func tomlFourDecimalDigits(raw: Array<Byte>, start: Int64): Option<Int64> {
    if (start < 0 || start + 4 > raw.size) { return None<Int64> }
    var value: Int64 = 0
    for (position in start..start + 4) {
        if (!tomlIsAsciiDigit(raw[position])) { return None<Int64> }
        value = value * 10 + Int64(raw[position] - b'0')
    }
    Some(value)
}
