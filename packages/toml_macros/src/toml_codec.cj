// SPDX-License-Identifier: Apache-2.0
macro package toml_macros

import std.ast.*
import std.collection.*

private class TomlMacroField {
    let name: String
    let typeText: String
    let explicitName: String
    let mutable: Bool
    let hasDefault: Bool
    let isOption: Bool
    let optionInner: String
    let codecExpression: String
    let flatten: Bool

    init(
        name: String,
        typeText: String,
        explicitName: String,
        mutable: Bool,
        hasDefault: Bool,
        isOption: Bool,
        optionInner: String,
        codecExpression: String,
        flatten: Bool
    ) {
        this.name = name
        this.typeText = typeText
        this.explicitName = explicitName
        this.mutable = mutable
        this.hasDefault = hasDefault
        this.isOption = isOption
        this.optionInner = optionInner
        this.codecExpression = codecExpression
        this.flatten = flatten
    }
}

private class TomlMacroParam {
    let name: String
    let typeText: String
    let hasDefault: Bool
    let defaultExpression: String

    init(name: String, typeText: String, hasDefault: Bool, defaultExpression: String) {
        this.name = name
        this.typeText = typeText
        this.hasDefault = hasDefault
        this.defaultExpression = defaultExpression
    }
}

private func tomlHasModifier(decl: Decl, kind: TokenKind): Bool {
    for (modifier in decl.modifiers) {
        if (modifier.keyword.kind == kind) { return true }
    }
    false
}

private func tomlHasAnnotation(decl: Decl, name: String): Bool {
    for (annotation in decl.annotations) {
        if (annotation.identifier.value == name) { return true }
    }
    false
}

private func tomlAnnotationArguments(decl: Decl, name: String): ArrayList<String> {
    let values = ArrayList<String>()
    for (annotation in decl.annotations) {
        if (annotation.identifier.value == name) {
            for (argument in annotation.arguments) {
                values.add(argument.expr.toTokens().toString().trimAscii())
            }
        }
    }
    values
}

private func tomlConstructorAnnotationArguments(constructor: Constructor, name: String): ArrayList<String> {
    let values = ArrayList<String>()
    for (annotation in constructor.annotations) {
        if (annotation.identifier.value == name) {
            for (argument in annotation.arguments) {
                values.add(argument.expr.toTokens().toString().trimAscii())
            }
        }
    }
    values
}

private func tomlUnwrapDecl(decl: Decl): Decl {
    match (decl) {
        case wrapper: MacroExpandDecl =>
            try { tomlUnwrapDecl(parseDecl(wrapper.macroInputs)) } catch (_) { decl }
        case _ => decl
    }
}

private func tomlFieldHasMarker(wrapper: Decl, field: Decl, name: String): Bool {
    if (tomlHasAnnotation(field, name) || tomlHasAnnotation(field, name + "Metadata")) { return true }
    match (wrapper) {
        case macroDecl: MacroExpandDecl =>
            if (macroDecl.identifier.value == name || macroDecl.identifier.value == name + "Metadata") {
                return true
            }
            try { tomlFieldHasMarker(parseDecl(macroDecl.macroInputs), field, name) } catch (_) { false }
        case _ => false
    }
}

private func tomlFieldArguments(wrapper: Decl, field: Decl, name: String): ArrayList<String> {
    let values = tomlAnnotationArguments(field, name)
    values.add(all: tomlAnnotationArguments(field, name + "Metadata"))
    var current = wrapper
    while (true) {
        match (current) {
            case macroDecl: MacroExpandDecl =>
                if ((macroDecl.identifier.value == name || macroDecl.identifier.value == name + "Metadata") &&
                    macroDecl.macroAttrs.size != 0) {
                    values.add(macroDecl.macroAttrs.toString().trimAscii())
                }
                try { current = parseDecl(macroDecl.macroInputs) } catch (_) { break }
            case _ => break
        }
    }
    values
}

private func tomlRetainedExpression(value: String): String {
    let text = value.trimAscii()
    if (text.size >= 2 && text.startsWith("\"") && text.endsWith("\"")) {
        text[1..text.size - 1]
    } else { text }
}

private func tomlHasInitializer(field: VarDecl): Bool {
    try { let _ = field.expr; true } catch (_: ASTException) { false }
}

private func tomlOptionInner(typeNode: TypeNode): Option<String> {
    match (typeNode) {
        case qualified: QualifiedType =>
            if (qualified.identifier.value == "Option" && qualified.typeArguments.size == 1) {
                return Some(qualified.typeArguments[0].toTokens().toString().trimAscii())
            }
        case parenthesized: ParenType => return tomlOptionInner(parenthesized.parenthesizedType)
        case _ => ()
    }
    None<String>
}

private func tomlOptionInnerText(typeText: String): Option<String> {
    let compact = typeText.replace(" ", "")
    if (compact.startsWith("Option<") && compact.endsWith(">") && compact.size > 8) {
        return Some(compact[7..compact.size - 1])
    }
    None<String>
}

private func tomlCollectFields(body: Body): ArrayList<TomlMacroField> {
    let fields = ArrayList<TomlMacroField>()
    let wireNames = HashSet<String>()
    for (member in body.decls) {
        let unwrapped = tomlUnwrapDecl(member)
        if (let Some(field) <- (unwrapped as VarDecl)) {
            if (tomlHasModifier(field, TokenKind.STATIC) || tomlFieldHasMarker(member, field, "TomlIgnore")) {
                continue
            }
            if (tomlHasModifier(field, TokenKind.PRIVATE)) {
                throw Exception("@TomlCodec cannot access private field `${field.identifier.value}`")
            }
            let typeNode = try { field.declType } catch (_: ASTException) {
                throw Exception("@TomlCodec requires an explicit type for `${field.identifier.value}`")
            }
            let typeText = typeNode.toTokens().toString().trimAscii()
            let names = tomlFieldArguments(member, field, "TomlName")
            if (names.size > 1) { throw Exception("field `${field.identifier.value}` has multiple @TomlName values") }
            let explicitName = if (names.isEmpty()) { "" } else { names[0] }
            if (!explicitName.isEmpty()) {
                if (wireNames.contains(explicitName)) { throw Exception("duplicate TOML field name ${explicitName}") }
                wireNames.add(explicitName)
            }
            let custom = tomlFieldArguments(member, field, "TomlUsing")
            if (custom.size > 1) { throw Exception("@TomlUsing accepts exactly one codec expression") }
            let astInner = tomlOptionInner(typeNode)
            let inner = if (astInner.isSome()) { astInner } else { tomlOptionInnerText(typeText) }
            fields.add(TomlMacroField(
                field.identifier.value,
                typeText,
                explicitName,
                field.keyword.kind == TokenKind.VAR,
                tomlHasInitializer(field) || tomlFieldHasMarker(member, field, "TomlDefault"),
                inner.isSome(),
                inner.getOrDefault({ => "" }),
                if (custom.isEmpty()) { "" } else { tomlRetainedExpression(custom[0]) },
                tomlFieldHasMarker(member, field, "TomlFlatten")
            ))
        }
    }
    fields
}

private func tomlUnwrapParams(params: Iterable<FuncParam>): ArrayList<FuncParam> {
    let result = ArrayList<FuncParam>()
    for (param in params) {
        match (param) {
            case wrapper: MacroExpandParam =>
                try { result.add((wrapper.macroInputDecl as FuncParam).getOrThrow()) }
                catch (_) { result.add(param) }
            case _ => result.add(param)
        }
    }
    result
}

private func tomlConstructorParams(body: Body): ArrayList<TomlMacroParam> {
    var best = ArrayList<FuncParam>()
    for (member in body.decls) {
        let declaration = tomlUnwrapDecl(member)
        match (declaration) {
            case function: FuncDecl =>
                if (function.identifier.value == "init" || function.identifier.kind == TokenKind.INIT) {
                    let params = tomlUnwrapParams(function.funcParams)
                    if (params.size > best.size) { best = params }
                }
            case primary: PrimaryCtorDecl =>
                let params = tomlUnwrapParams(primary.funcParams)
                if (params.size > best.size) { best = params }
            case _ => ()
        }
    }
    let result = ArrayList<TomlMacroParam>()
    for (param in best) {
        var hasDefault = false
        var expression = ""
        try {
            expression = param.expr.toTokens().toString().trimAscii()
            hasDefault = true
        } catch (_: ASTException) {}
        result.add(TomlMacroParam(param.identifier.value,
            param.paramType.toTokens().toString().trimAscii(), hasDefault, expression))
    }
    result
}

private func tomlGenericNames(decl: Decl): ArrayList<String> {
    let result = ArrayList<String>()
    try {
        for (token in decl.genericParam.parameters) {
            if (token.kind == TokenKind.IDENTIFIER) { result.add(token.value) }
        }
    } catch (_: ASTException) {}
    result
}

private func tomlJoin(values: Collection<String>, separator: String): String {
    let output = StringBuilder()
    var first = true
    for (value in values) {
        if (!first) { output.append(separator) }
        output.append(value)
        first = false
    }
    output.toString()
}

private func tomlGenericText(names: ArrayList<String>): String {
    if (names.isEmpty()) { "" } else { "<" + tomlJoin(names, ", ") + ">" }
}

private func tomlTypeUses(typeText: String, name: String): Bool {
    for (token in cangjieLex(typeText)) {
        if (token.kind == TokenKind.IDENTIFIER && token.value == name) { return true }
    }
    false
}

private func tomlConstraints(
    decl: Decl,
    fields: ArrayList<TomlMacroField>,
    generics: ArrayList<String>
): String {
    let parts = ArrayList<String>()
    for (constraint in decl.genericConstraint) {
        let text = constraint.toTokens().toString().trimAscii()
        parts.add(if (text.startsWith("where ")) { text[6..text.size] } else { text })
    }
    for (name in generics) {
        var used = false
        for (field in fields) {
            if (field.codecExpression.isEmpty() && tomlTypeUses(field.typeText, name)) { used = true; break }
        }
        if (used) { parts.add("${name} <: TomlCodecProvider") }
    }
    if (parts.isEmpty()) { "" } else { " where " + tomlJoin(parts, ", ") }
}

private func tomlDefaultCodec(typeText: String): String {
    let compact = typeText.replace(" ", "")
    match (compact) {
        case "String" => return "TomlCodecs.string"
        case "Bool" => return "TomlCodecs.bool"
        case "Int64" => return "TomlCodecs.int64"
        case "Int32" => return "TomlCodecs.int32"
        case "Int16" => return "TomlCodecs.int16"
        case "Int8" => return "TomlCodecs.int8"
        case "UInt64" => return "TomlCodecs.uint64"
        case "UInt32" => return "TomlCodecs.uint32"
        case "UInt16" => return "TomlCodecs.uint16"
        case "UInt8" => return "TomlCodecs.uint8"
        case "Float64" => return "TomlCodecs.float64"
        case "Float32" => return "TomlCodecs.float32"
        case "BigInt" => return "TomlCodecs.bigInt"
        case "TomlValue" => return "TomlCodecs.value"
        case "TomlLocalDate" => return "TomlCodecs.localDate"
        case "TomlLocalTime" => return "TomlCodecs.localTime"
        case "TomlLocalDateTime" => return "TomlCodecs.localDateTime"
        case "TomlOffsetDateTime" => return "TomlCodecs.offsetDateTime"
        case "DateTime" => return "TomlCodecs.dateTime"
        case _ => ()
    }
    if (compact.startsWith("Option<") && compact.endsWith(">")) {
        return "TomlCodecs.option(" + tomlDefaultCodec(compact[7..compact.size - 1]) + ")"
    }
    if (compact.startsWith("Array<") && compact.endsWith(">")) {
        return "TomlCodecs.array(" + tomlDefaultCodec(compact[6..compact.size - 1]) + ")"
    }
    if (compact.startsWith("ArrayList<") && compact.endsWith(">")) {
        return "TomlCodecs.arrayList(" + tomlDefaultCodec(compact[10..compact.size - 1]) + ")"
    }
    try {
        match (parseType(cangjieLex(typeText))) {
            case qualified: QualifiedType =>
                let args = qualified.typeArguments
                if (qualified.identifier.value == "Option" && args.size == 1) {
                    return "TomlCodecs.option(" + tomlDefaultCodec(args[0].toTokens().toString().trimAscii()) + ")"
                }
                if (qualified.identifier.value == "Array" && args.size == 1) {
                    return "TomlCodecs.array(" + tomlDefaultCodec(args[0].toTokens().toString().trimAscii()) + ")"
                }
                if (qualified.identifier.value == "ArrayList" && args.size == 1) {
                    return "TomlCodecs.arrayList(" + tomlDefaultCodec(args[0].toTokens().toString().trimAscii()) + ")"
                }
                if (qualified.identifier.value == "HashMap" && args.size == 2 &&
                    args[0].toTokens().toString().trimAscii() == "String") {
                    return "TomlCodecs.stringMap(" + tomlDefaultCodec(args[1].toTokens().toString().trimAscii()) + ")"
                }
            case parenthesized: ParenType =>
                return tomlDefaultCodec(parenthesized.parenthesizedType.toTokens().toString().trimAscii())
            case _ => ()
        }
    } catch (_) {}
    "tomlCodecOf<${typeText}>()"
}

private func tomlFieldCodec(field: TomlMacroField): String {
    if (field.codecExpression.isEmpty()) { "__tomlCodec_${field.name}" }
    else { "(${field.codecExpression})" }
}

private func tomlFieldName(field: TomlMacroField, optionsExpression: String): String {
    if (!field.explicitName.isEmpty()) { field.explicitName }
    else { "TomlGeneratedSupportV1.fieldName(\"${field.name}\", ${optionsExpression}.fieldNaming)" }
}

private func tomlFieldByName(fields: ArrayList<TomlMacroField>, name: String): Option<TomlMacroField> {
    for (field in fields) { if (field.name == name) { return Some(field) } }
    None<TomlMacroField>
}

private func tomlParamByName(params: ArrayList<TomlMacroParam>, name: String): Option<TomlMacroParam> {
    for (param in params) { if (param.name == name) { return Some(param) } }
    None<TomlMacroParam>
}

private func tomlRequired(field: TomlMacroField, params: ArrayList<TomlMacroParam>): Bool {
    if (field.isOption) { return false }
    match (tomlParamByName(params, field.name)) {
        case Some(param) => !param.hasDefault
        case None => !field.hasDefault
    }
}

private func tomlAppendLine(output: StringBuilder, indent: Int64, line: String): Unit {
    for (_ in 0..indent) { output.append("    ") }
    output.append(line)
    output.append("\n")
}

private func tomlIsFieldMetadataName(value: String): Bool {
    value == "TomlName" || value == "TomlNameMetadata" ||
        value == "TomlUsing" || value == "TomlUsingMetadata" ||
        value == "TomlIgnore" || value == "TomlIgnoreMetadata" ||
        value == "TomlDefault" || value == "TomlDefaultMetadata" ||
        value == "TomlFlatten" || value == "TomlFlattenMetadata"
}

/// Field annotations are compile-time instructions, not runtime attributes.
/// Remove their tokens from the retained declaration after collecting them.
private func tomlStripFieldMetadata(input: Tokens): Tokens {
    let source = ArrayList<Token>()
    for (token in input) { source.add(token) }
    let result = Tokens()
    var index: Int64 = 0
    while (index < source.size) {
        if (source[index].kind == TokenKind.AT && index + 1 < source.size &&
            tomlIsFieldMetadataName(source[index + 1].value)) {
            index += 2
            if (index < source.size && source[index].kind == TokenKind.LSQUARE) {
                var depth: Int64 = 0
                while (index < source.size) {
                    if (source[index].kind == TokenKind.LSQUARE) { depth++ }
                    else if (source[index].kind == TokenKind.RSQUARE) {
                        depth--
                        index++
                        if (depth == 0) { break }
                        continue
                    }
                    index++
                }
            }
            continue
        }
        result.append(source[index])
        index++
    }
    result
}

private func tomlRenderRecord(decl: Decl, body: Body): Tokens {
    let name = decl.identifier.value
    let fields = tomlCollectFields(body)
    let params = tomlConstructorParams(body)
    let generics = tomlGenericNames(decl)
    let genericText = tomlGenericText(generics)
    let targetType = name + genericText
    let constraints = tomlConstraints(decl, fields, generics)
    let codecName = "__TomlGeneratedCodec_${name}"
    let output = StringBuilder()

    for (field in fields) {
        if (!field.mutable && tomlParamByName(params, field.name).isNone() && !field.hasDefault) {
            throw Exception("immutable field `${field.name}` requires a constructor parameter or default")
        }
    }

    tomlAppendLine(output, 0, "private class ${codecName}${genericText} <: TomlObjectCodec<${targetType}>${constraints} {")
    for (field in fields) {
        if (field.codecExpression.isEmpty()) {
            tomlAppendLine(output, 1, "private let __tomlCodec_${field.name}: TomlCodec<${field.typeText}> = ${tomlDefaultCodec(field.typeText)}")
        }
    }

    tomlAppendLine(output, 1, "public func fieldNames(options: TomlCodecOptions): ArrayList<String> {")
    tomlAppendLine(output, 2, "let __names = ArrayList<String>()")
    for (field in fields) {
        if (field.flatten) {
            tomlAppendLine(output, 2, "match (${tomlFieldCodec(field)}) {")
            tomlAppendLine(output, 3, "case __object: TomlObjectCodec<${field.typeText}> => __names.add(all: __object.fieldNames(options))")
            tomlAppendLine(output, 3, "case _ => ()")
            tomlAppendLine(output, 2, "}")
        } else {
            tomlAppendLine(output, 2, "__names.add(${tomlFieldName(field, "options")})")
        }
    }
    tomlAppendLine(output, 2, "__names")
    tomlAppendLine(output, 1, "}")

    tomlAppendLine(output, 1, "public func encode(value: ${targetType}, context: TomlEncodeContext): TomlOutcome<TomlValue> {")
    tomlAppendLine(output, 2, "match (encodeFields(value, context)) {")
    tomlAppendLine(output, 3, "case TomlOutcome<TomlTable>.Success(__table, __diagnostics) => TomlOutcome<TomlValue>.Success(__table, __diagnostics)")
    tomlAppendLine(output, 3, "case TomlOutcome<TomlTable>.Failure(__diagnostics) => TomlOutcome<TomlValue>.Failure(__diagnostics)")
    tomlAppendLine(output, 2, "}")
    tomlAppendLine(output, 1, "}")

    tomlAppendLine(output, 1, "public func encodeFields(value: ${targetType}, context: TomlEncodeContext): TomlOutcome<TomlTable> {")
    tomlAppendLine(output, 2, "let __table = TomlTable()")
    tomlAppendLine(output, 2, "let __diagnostics = ArrayList<TomlDiagnostic>()")
    tomlAppendLine(output, 2, "var __failed = false")
    for (field in fields) {
        let codec = tomlFieldCodec(field)
        if (field.flatten) {
            tomlAppendLine(output, 2, "match (${codec}) {")
            tomlAppendLine(output, 3, "case __object: TomlObjectCodec<${field.typeText}> =>")
            tomlAppendLine(output, 4, "match (__object.encodeFields(value.${field.name}, context)) {")
            tomlAppendLine(output, 5, "case TomlOutcome<TomlTable>.Success(__nested, __nestedDiagnostics) =>")
            tomlAppendLine(output, 6, "__diagnostics.add(all: __nestedDiagnostics)")
            tomlAppendLine(output, 6, "for (__key in __nested.keys()) { if (__table.contains(__key)) { __diagnostics.add(TomlGeneratedSupportV1.diagnostic(\"flatten_conflict\", \"flattened field conflicts with '\" + __key + \"'\", context.atKey(__key).path)); __failed = true } else { __table.put(__key, __nested[__key]) } }")
            tomlAppendLine(output, 5, "case TomlOutcome<TomlTable>.Failure(__nestedDiagnostics) => __diagnostics.add(all: __nestedDiagnostics); __failed = true")
            tomlAppendLine(output, 4, "}")
            tomlAppendLine(output, 3, "case _ => __diagnostics.add(TomlGeneratedSupportV1.diagnostic(\"codec_contract\", \"@TomlFlatten requires TomlObjectCodec\", context.path)); __failed = true")
            tomlAppendLine(output, 2, "}")
        } else {
            let nameExpression = tomlFieldName(field, "context.options")
            if (field.isOption) {
                tomlAppendLine(output, 2, "match (value.${field.name}) {")
                tomlAppendLine(output, 3, "case Some(_) =>")
                tomlAppendLine(output, 4, "let __name = ${nameExpression}")
                tomlAppendLine(output, 4, "match (${codec}.encode(value.${field.name}, context.atKey(__name))) {")
                tomlAppendLine(output, 5, "case TomlOutcome<TomlValue>.Success(__encoded, __itemDiagnostics) => __diagnostics.add(all: __itemDiagnostics); __table.put(__name, __encoded)")
                tomlAppendLine(output, 5, "case TomlOutcome<TomlValue>.Failure(__itemDiagnostics) => __diagnostics.add(all: __itemDiagnostics); __failed = true")
                tomlAppendLine(output, 4, "}")
                tomlAppendLine(output, 3, "case None => ()")
                tomlAppendLine(output, 2, "}")
            } else {
                tomlAppendLine(output, 2, "let __name_${field.name} = ${nameExpression}")
                tomlAppendLine(output, 2, "match (${codec}.encode(value.${field.name}, context.atKey(__name_${field.name}))) {")
                tomlAppendLine(output, 3, "case TomlOutcome<TomlValue>.Success(__encoded, __itemDiagnostics) => __diagnostics.add(all: __itemDiagnostics); __table.put(__name_${field.name}, __encoded)")
                tomlAppendLine(output, 3, "case TomlOutcome<TomlValue>.Failure(__itemDiagnostics) => __diagnostics.add(all: __itemDiagnostics); __failed = true")
                tomlAppendLine(output, 2, "}")
            }
        }
    }
    tomlAppendLine(output, 2, "if (__failed) { TomlOutcome<TomlTable>.Failure(__diagnostics) } else { TomlOutcome<TomlTable>.Success(__table, __diagnostics) }")
    tomlAppendLine(output, 1, "}")

    tomlAppendLine(output, 1, "public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<${targetType}> {")
    tomlAppendLine(output, 2, "match (value) {")
    tomlAppendLine(output, 3, "case __table: TomlTable => decodeFields(__table, context, true)")
    tomlAppendLine(output, 3, "case _ => TomlGeneratedSupportV1.failure<${targetType}>(\"type_mismatch\", \"expected a TOML table\", context.path)")
    tomlAppendLine(output, 2, "}")
    tomlAppendLine(output, 1, "}")

    tomlAppendLine(output, 1, "public func decodeFields(table: TomlTable, context: TomlDecodeContext, checkUnknown: Bool): TomlOutcome<${targetType}> {")
    tomlAppendLine(output, 2, "let __diagnostics = ArrayList<TomlDiagnostic>()")
    tomlAppendLine(output, 2, "var __failed = false")
    for (field in fields) {
        tomlAppendLine(output, 2, "var __value_${field.name}: Option<${field.typeText}> = None<${field.typeText}>")
    }
    for (field in fields) {
        let codec = tomlFieldCodec(field)
        if (field.flatten) {
            tomlAppendLine(output, 2, "match (${codec}) {")
            tomlAppendLine(output, 3, "case __object: TomlObjectCodec<${field.typeText}> =>")
            tomlAppendLine(output, 4, "match (__object.decodeFields(table, context, false)) {")
            tomlAppendLine(output, 5, "case TomlOutcome<${field.typeText}>.Success(__decoded, __itemDiagnostics) => __diagnostics.add(all: __itemDiagnostics); __value_${field.name} = Some(__decoded)")
            tomlAppendLine(output, 5, "case TomlOutcome<${field.typeText}>.Failure(__itemDiagnostics) => __diagnostics.add(all: __itemDiagnostics); __failed = true")
            tomlAppendLine(output, 4, "}")
            tomlAppendLine(output, 3, "case _ => __diagnostics.add(TomlGeneratedSupportV1.diagnostic(\"codec_contract\", \"@TomlFlatten requires TomlObjectCodec\", context.path)); __failed = true")
            tomlAppendLine(output, 2, "}")
        } else {
            let nameExpression = tomlFieldName(field, "context.options")
            tomlAppendLine(output, 2, "let __decodeName_${field.name} = ${nameExpression}")
            tomlAppendLine(output, 2, "match (table.get(__decodeName_${field.name})) {")
            tomlAppendLine(output, 3, "case Some(__raw) =>")
            tomlAppendLine(output, 4, "match (${codec}.decode(__raw, context.atKey(__decodeName_${field.name}))) {")
            tomlAppendLine(output, 5, "case TomlOutcome<${field.typeText}>.Success(__decoded, __itemDiagnostics) => __diagnostics.add(all: __itemDiagnostics); __value_${field.name} = Some(__decoded)")
            tomlAppendLine(output, 5, "case TomlOutcome<${field.typeText}>.Failure(__itemDiagnostics) => __diagnostics.add(all: __itemDiagnostics); __failed = true")
            tomlAppendLine(output, 4, "}")
            tomlAppendLine(output, 3, "case None =>")
            if (field.isOption) {
                tomlAppendLine(output, 4, "__value_${field.name} = Some(None<${field.optionInner}>)")
            } else if (tomlRequired(field, params)) {
                tomlAppendLine(output, 4, "__diagnostics.add(TomlGeneratedSupportV1.diagnostic(\"missing_field\", \"required field '${field.name}' is missing\", context.atKey(__decodeName_${field.name}).path)); __failed = true")
            } else {
                tomlAppendLine(output, 4, "()")
            }
            tomlAppendLine(output, 2, "}")
        }
    }
    tomlAppendLine(output, 2, "if (checkUnknown) { let __unknown = TomlGeneratedSupportV1.unknownFields(table, fieldNames(context.options), context); if (!__unknown.isEmpty()) { __diagnostics.add(all: __unknown); __failed = true } }")
    tomlAppendLine(output, 2, "if (__failed) { return TomlOutcome<${targetType}>.Failure(__diagnostics) }")

    if (!params.isEmpty()) {
        let args = ArrayList<String>()
        for (param in params) {
            match (tomlFieldByName(fields, param.name)) {
                case Some(field) =>
                    if (param.hasDefault) {
                        args.add("__value_${field.name}.getOrDefault({ => ${param.defaultExpression} })")
                    } else {
                        args.add("__value_${field.name}.getOrThrow()")
                    }
                case None =>
                    if (param.hasDefault) { args.add(param.defaultExpression) }
                    else { throw Exception("constructor parameter `${param.name}` has no TOML field") }
            }
        }
        tomlAppendLine(output, 2, "let __result = ${targetType}(" + tomlJoin(args, ", ") + ")")
    } else {
        tomlAppendLine(output, 2, "let __result = ${targetType}()")
    }
    for (field in fields) {
        var covered = false
        for (param in params) { if (param.name == field.name) { covered = true; break } }
        if (!covered && field.mutable) {
            tomlAppendLine(output, 2, "match (__value_${field.name}) { case Some(__fieldValue) => __result.${field.name} = __fieldValue; case None => () }")
        } else if (!covered && !field.mutable && !field.hasDefault) {
            throw Exception("immutable field `${field.name}` is not initialized by the selected constructor")
        }
    }
    tomlAppendLine(output, 2, "TomlOutcome<${targetType}>.Success(__result, __diagnostics)")
    tomlAppendLine(output, 1, "}")
    tomlAppendLine(output, 0, "}")

    let visibility = if (tomlHasModifier(decl, TokenKind.PUBLIC)) { "public " } else { "" }
    if (generics.isEmpty()) {
        tomlAppendLine(output, 0, "${visibility}let ${name}Toml: TomlCodec<${name}> = ${codecName}()")
        if (!tomlHasModifier(decl, TokenKind.OPEN) && !tomlHasModifier(decl, TokenKind.ABSTRACT)) {
            tomlAppendLine(output, 0, "extend ${name} <: TomlCodecProvider {")
            tomlAppendLine(output, 1, "public static func tomlCodec(): TomlAnyCodec { eraseTomlCodec(${name}Toml) }")
            tomlAppendLine(output, 0, "}")
        }
    } else {
        tomlAppendLine(output, 0, "${visibility}func ${name}Toml${genericText}(): TomlCodec<${targetType}>${constraints} { ${codecName}${genericText}() }")
        tomlAppendLine(output, 0, "extend${genericText} ${targetType} <: TomlCodecProvider${constraints} {")
        tomlAppendLine(output, 1, "public static func tomlCodec(): TomlAnyCodec { eraseTomlCodec(${name}Toml${genericText}()) }")
        tomlAppendLine(output, 0, "}")
    }
    cangjieLex(output.toString())
}

private func tomlEnumWireName(constructor: Constructor): String {
    let names = tomlConstructorAnnotationArguments(constructor, "TomlName")
    if (names.size > 1) { throw Exception("enum case has multiple @TomlName values") }
    if (names.isEmpty()) { "\"${constructor.identifier.value}\"" } else { names[0] }
}

private func tomlRenderEnum(decl: EnumDecl): Tokens {
    let name = decl.identifier.value
    for (constructor in decl.constructors) {
        if (!constructor.typeArguments.isEmpty()) {
            throw Exception("@TomlCodec enum payloads require an explicit manual codec in v0.1")
        }
    }
    let output = StringBuilder()
    let codecName = "__TomlGeneratedCodec_${name}"
    tomlAppendLine(output, 0, "private class ${codecName} <: TomlCodec<${name}> {")
    tomlAppendLine(output, 1, "public func encode(value: ${name}, context: TomlEncodeContext): TomlOutcome<TomlValue> {")
    tomlAppendLine(output, 2, "let _ = context")
    tomlAppendLine(output, 2, "let __text = match (value) {")
    for (constructor in decl.constructors) {
        tomlAppendLine(output, 3, "case ${name}.${constructor.identifier.value} => ${tomlEnumWireName(constructor)}")
    }
    tomlAppendLine(output, 2, "}")
    tomlAppendLine(output, 2, "TomlOutcome<TomlValue>.Success(TomlString(__text), ArrayList<TomlDiagnostic>())")
    tomlAppendLine(output, 1, "}")
    tomlAppendLine(output, 1, "public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<${name}> {")
    tomlAppendLine(output, 2, "match (value) {")
    tomlAppendLine(output, 3, "case __string: TomlString =>")
    tomlAppendLine(output, 4, "match (__string.value) {")
    for (constructor in decl.constructors) {
        tomlAppendLine(output, 5, "case ${tomlEnumWireName(constructor)} => TomlOutcome<${name}>.Success(${name}.${constructor.identifier.value}, ArrayList<TomlDiagnostic>())")
    }
    tomlAppendLine(output, 5, "case _ => TomlGeneratedSupportV1.failure<${name}>(\"unknown_enum_case\", \"unknown TOML enum value: \" + __string.value, context.path)")
    tomlAppendLine(output, 4, "}")
    tomlAppendLine(output, 3, "case _ => TomlGeneratedSupportV1.failure<${name}>(\"type_mismatch\", \"expected a TOML string for enum ${name}\", context.path)")
    tomlAppendLine(output, 2, "}")
    tomlAppendLine(output, 1, "}")
    tomlAppendLine(output, 0, "}")
    let visibility = if (tomlHasModifier(decl, TokenKind.PUBLIC)) { "public " } else { "" }
    tomlAppendLine(output, 0, "${visibility}let ${name}Toml: TomlCodec<${name}> = ${codecName}()")
    tomlAppendLine(output, 0, "extend ${name} <: TomlCodecProvider {")
    tomlAppendLine(output, 1, "public static func tomlCodec(): TomlAnyCodec { eraseTomlCodec(${name}Toml) }")
    tomlAppendLine(output, 0, "}")
    cangjieLex(output.toString())
}

/// Derives a codec entirely against toml.generated_support.v1-style public
/// contracts. No reflection, DataModel, or runtime registry is used.
public macro TomlCodec(input: Tokens): Tokens {
    let declaration = parseDecl(input)
    let generated = match (declaration) {
        case classDecl: ClassDecl => tomlRenderRecord(classDecl, classDecl.body)
        case structDecl: StructDecl => tomlRenderRecord(structDecl, structDecl.body)
        case enumDecl: EnumDecl => tomlRenderEnum(enumDecl)
        case _ => throw Exception("@TomlCodec supports class, struct, and enum declarations")
    }
    tomlStripFieldMetadata(input) + Token(TokenKind.NL).toTokens() + generated
}

public macro TomlName(attrs: Tokens, input: Tokens): Tokens {
    quote(@TomlNameMetadata[$attrs] $input)
}

public macro TomlUsing(attrs: Tokens, input: Tokens): Tokens {
    quote(@TomlUsingMetadata[$attrs] $input)
}

public macro TomlIgnore(input: Tokens): Tokens { quote(@TomlIgnoreMetadata $input) }
public macro TomlDefault(input: Tokens): Tokens { quote(@TomlDefaultMetadata $input) }
public macro TomlFlatten(input: Tokens): Tokens { quote(@TomlFlattenMetadata $input) }

// Metadata wrappers are consumed by @TomlCodec, then erased from the retained
// declaration during their own expansion.
public macro TomlNameMetadata(attrs: Tokens, input: Tokens): Tokens { let _ = attrs; input }
public macro TomlUsingMetadata(attrs: Tokens, input: Tokens): Tokens { let _ = attrs; input }
public macro TomlIgnoreMetadata(input: Tokens): Tokens { input }
public macro TomlDefaultMetadata(input: Tokens): Tokens { input }
public macro TomlFlattenMetadata(input: Tokens): Tokens { input }
