// SPDX-License-Identifier: Apache-2.0
macro package toml_schema_macros

import std.ast.*
import std.collection.*

private class TomlSchemaMacroField {
    let name: String
    let typeText: String
    let wireExpression: String
    let optional: Bool

    init(name: String, typeText: String, wireExpression: String, optional: Bool) {
        this.name = name
        this.typeText = typeText
        this.wireExpression = wireExpression
        this.optional = optional
    }
}

private func schemaHasModifier(decl: Decl, kind: TokenKind): Bool {
    for (modifier in decl.modifiers) {
        if (modifier.keyword.kind == kind) { return true }
    }
    false
}

private func schemaHasAnnotation(decl: Decl, name: String): Bool {
    for (annotation in decl.annotations) {
        if (annotation.identifier.value == name ||
            annotation.identifier.value == name + "Metadata") { return true }
    }
    false
}

private func schemaAnnotationArguments(decl: Decl, name: String): ArrayList<String> {
    let result = ArrayList<String>()
    for (annotation in decl.annotations) {
        if (annotation.identifier.value == name ||
            annotation.identifier.value == name + "Metadata") {
            for (argument in annotation.arguments) {
                result.add(argument.expr.toTokens().toString().trimAscii())
            }
        }
    }
    result
}

private func schemaUnwrapDecl(decl: Decl): Decl {
    match (decl) {
        case wrapper: MacroExpandDecl =>
            try { schemaUnwrapDecl(parseDecl(wrapper.macroInputs)) } catch (_) { decl }
        case _ => decl
    }
}

private func schemaFieldHasMarker(wrapper: Decl, field: Decl, name: String): Bool {
    if (schemaHasAnnotation(field, name)) { return true }
    match (wrapper) {
        case macroDecl: MacroExpandDecl =>
            if (macroDecl.identifier.value == name ||
                macroDecl.identifier.value == name + "Metadata") { return true }
            try { schemaFieldHasMarker(parseDecl(macroDecl.macroInputs), field, name) }
            catch (_) { false }
        case _ => false
    }
}

private func schemaFieldArguments(wrapper: Decl, field: Decl, name: String): ArrayList<String> {
    let result = schemaAnnotationArguments(field, name)
    var current = wrapper
    while (true) {
        match (current) {
            case macroDecl: MacroExpandDecl =>
                if ((macroDecl.identifier.value == name ||
                    macroDecl.identifier.value == name + "Metadata") &&
                    macroDecl.macroAttrs.size != 0) {
                    result.add(macroDecl.macroAttrs.toString().trimAscii())
                }
                try { current = parseDecl(macroDecl.macroInputs) } catch (_) { break }
            case _ => break
        }
    }
    result
}

private func schemaHasInitializer(field: VarDecl): Bool {
    try { let _ = field.expr; true } catch (_: ASTException) { false }
}

private func schemaOptionInner(typeText: String): Option<String> {
    let compact = typeText.replace(" ", "")
    if (compact.startsWith("Option<") && compact.endsWith(">") && compact.size > 8) {
        Some(compact[7..compact.size - 1])
    } else { None<String> }
}

private func schemaCollectFields(body: Body): ArrayList<TomlSchemaMacroField> {
    let result = ArrayList<TomlSchemaMacroField>()
    let names = HashSet<String>()
    for (member in body.decls) {
        let unwrapped = schemaUnwrapDecl(member)
        if (let Some(field) <- (unwrapped as VarDecl)) {
            if (schemaHasModifier(field, TokenKind.STATIC) ||
                schemaFieldHasMarker(member, field, "TomlSchemaIgnore")) { continue }
            let typeNode = try { field.declType } catch (_: ASTException) {
                throw Exception("@TomlSchema requires an explicit type for `${field.identifier.value}`")
            }
            let typeText = typeNode.toTokens().toString().trimAscii()
            let wireNames = schemaFieldArguments(member, field, "TomlSchemaName")
            if (wireNames.size > 1) {
                throw Exception("field `${field.identifier.value}` has multiple @TomlSchemaName values")
            }
            let wireExpression = if (wireNames.isEmpty()) {
                "\"${field.identifier.value}\""
            } else { wireNames[0] }
            if (names.contains(wireExpression)) {
                throw Exception("duplicate generated TOML schema property ${wireExpression}")
            }
            names.add(wireExpression)
            result.add(TomlSchemaMacroField(
                field.identifier.value,
                typeText,
                wireExpression,
                schemaOptionInner(typeText).isSome() || schemaHasInitializer(field) ||
                    schemaFieldHasMarker(member, field, "TomlSchemaOptional")
            ))
        }
    }
    result
}

private func schemaGenericNames(decl: Decl): ArrayList<String> {
    let result = ArrayList<String>()
    try {
        for (token in decl.genericParam.parameters) {
            if (token.kind == TokenKind.IDENTIFIER) { result.add(token.value) }
        }
    } catch (_: ASTException) {}
    result
}

private func schemaJoin(values: Collection<String>, separator: String): String {
    let output = StringBuilder()
    var first = true
    for (value in values) {
        if (!first) { output.append(separator) }
        output.append(value)
        first = false
    }
    output.toString()
}

private func schemaGenericText(names: ArrayList<String>): String {
    if (names.isEmpty()) { "" } else { "<" + schemaJoin(names, ", ") + ">" }
}

private func schemaTypeUses(typeText: String, name: String): Bool {
    for (token in cangjieLex(typeText)) {
        if (token.kind == TokenKind.IDENTIFIER && token.value == name) { return true }
    }
    false
}

private func schemaConstraints(
    decl: Decl,
    fields: ArrayList<TomlSchemaMacroField>,
    generics: ArrayList<String>
): String {
    let constraints = ArrayList<String>()
    for (constraint in decl.genericConstraint) {
        let text = constraint.toTokens().toString().trimAscii()
        constraints.add(if (text.startsWith("where ")) { text[6..text.size] } else { text })
    }
    for (name in generics) {
        var used = false
        for (field in fields) {
            if (schemaTypeUses(field.typeText, name)) { used = true; break }
        }
        if (used) { constraints.add("${name} <: TomlSchemaProvider") }
    }
    if (constraints.isEmpty()) { "" }
    else { " where " + schemaJoin(constraints, ", ") }
}

private func schemaSplitGeneric(typeText: String, container: String): Option<String> {
    let compact = typeText.replace(" ", "")
    let prefix = container + "<"
    if (compact.startsWith(prefix) && compact.endsWith(">") &&
        compact.size > prefix.size + 1) {
        Some(compact[prefix.size..compact.size - 1])
    } else { None<String> }
}

private func schemaExpression(typeText: String): String {
    let compact = typeText.replace(" ", "")
    match (compact) {
        case "String" => return "TomlSchema.string()"
        case "Bool" => return "TomlSchema.boolean()"
        case "Int8" | "Int16" | "Int32" | "Int64" |
            "UInt8" | "UInt16" | "UInt32" | "UInt64" | "BigInt" =>
            return "TomlSchema.integer()"
        case "Float32" | "Float64" => return "TomlSchema.float()"
        case "TomlValue" => return "TomlSchema.any()"
        case "TomlOffsetDateTime" | "DateTime" => return "TomlSchema.offsetDateTime()"
        case "TomlLocalDateTime" => return "TomlSchema.localDateTime()"
        case "TomlLocalDate" => return "TomlSchema.localDate()"
        case "TomlLocalTime" => return "TomlSchema.localTime()"
        case _ => ()
    }
    match (schemaSplitGeneric(typeText, "Option")) {
        case Some(inner) => return schemaExpression(inner)
        case None => ()
    }
    match (schemaSplitGeneric(typeText, "Array")) {
        case Some(inner) => return "TomlSchema.array(" + schemaExpression(inner) + ")"
        case None => ()
    }
    match (schemaSplitGeneric(typeText, "ArrayList")) {
        case Some(inner) => return "TomlSchema.array(" + schemaExpression(inner) + ")"
        case None => ()
    }
    try {
        match (parseType(cangjieLex(typeText))) {
            case qualified: QualifiedType =>
                if (qualified.identifier.value == "HashMap" &&
                    qualified.typeArguments.size == 2 &&
                    qualified.typeArguments[0].toTokens().toString().trimAscii() == "String") {
                    return "TomlSchema.table().additionalProperties(" +
                        schemaExpression(qualified.typeArguments[1].toTokens().toString().trimAscii()) + ")"
                }
            case parenthesized: ParenType =>
                return schemaExpression(parenthesized.parenthesizedType.toTokens().toString().trimAscii())
            case _ => ()
        }
    } catch (_) {}
    "tomlSchemaOf<${typeText}>()"
}

private func schemaAppendLine(output: StringBuilder, indent: Int64, line: String): Unit {
    for (_ in 0..indent) { output.append("    ") }
    output.append(line)
    output.append("\n")
}

private func schemaIsMetadataName(value: String): Bool {
    value == "TomlSchemaName" || value == "TomlSchemaNameMetadata" ||
        value == "TomlSchemaIgnore" || value == "TomlSchemaIgnoreMetadata" ||
        value == "TomlSchemaOptional" || value == "TomlSchemaOptionalMetadata"
}

private func schemaStripMetadata(input: Tokens): Tokens {
    let source = ArrayList<Token>()
    for (token in input) { source.add(token) }
    let output = Tokens()
    var index: Int64 = 0
    while (index < source.size) {
        if (source[index].kind == TokenKind.AT && index + 1 < source.size &&
            schemaIsMetadataName(source[index + 1].value)) {
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
        output.append(source[index])
        index++
    }
    output
}

private func schemaRenderRecord(decl: Decl, body: Body): Tokens {
    let name = decl.identifier.value
    let fields = schemaCollectFields(body)
    let generics = schemaGenericNames(decl)
    let genericText = schemaGenericText(generics)
    let targetType = name + genericText
    let constraints = schemaConstraints(decl, fields, generics)
    let builder = "__build${name}TomlSchema"
    let output = StringBuilder()
    let visibility = if (schemaHasModifier(decl, TokenKind.PUBLIC)) { "public " } else { "" }

    schemaAppendLine(output, 0, "private func ${builder}${genericText}(): TomlSchema${constraints} {")
    schemaAppendLine(output, 1, "let __schema = TomlSchema.table().additionalProperties(false)")
    for (field in fields) {
        schemaAppendLine(output, 1,
            "let _ = __schema.property(${field.wireExpression}, ${schemaExpression(field.typeText)}, required: ${(!field.optional).toString()})")
    }
    schemaAppendLine(output, 1, "__schema")
    schemaAppendLine(output, 0, "}")
    if (generics.isEmpty()) {
        schemaAppendLine(output, 0,
            "${visibility}let ${name}TomlSchema: TomlSchema = ${builder}()")
        if (!schemaHasModifier(decl, TokenKind.OPEN) &&
            !schemaHasModifier(decl, TokenKind.ABSTRACT)) {
            schemaAppendLine(output, 0, "extend ${name} <: TomlSchemaProvider {")
            schemaAppendLine(output, 1,
                "public static func tomlSchema(): TomlSchema { ${name}TomlSchema }")
            schemaAppendLine(output, 0, "}")
        }
    } else {
        schemaAppendLine(output, 0,
            "${visibility}func ${name}TomlSchema${genericText}(): TomlSchema${constraints} { ${builder}${genericText}() }")
        schemaAppendLine(output, 0,
            "extend${genericText} ${targetType} <: TomlSchemaProvider${constraints} {")
        schemaAppendLine(output, 1,
            "public static func tomlSchema(): TomlSchema { ${name}TomlSchema${genericText}() }")
        schemaAppendLine(output, 0, "}")
    }
    cangjieLex(output.toString())
}

private func schemaEnumWireExpression(constructor: Constructor): String {
    let names = ArrayList<String>()
    for (annotation in constructor.annotations) {
        if (annotation.identifier.value == "TomlSchemaName" ||
            annotation.identifier.value == "TomlSchemaNameMetadata") {
            for (argument in annotation.arguments) {
                names.add(argument.expr.toTokens().toString().trimAscii())
            }
        }
    }
    if (names.size > 1) { throw Exception("enum case has multiple @TomlSchemaName values") }
    if (names.isEmpty()) { "\"${constructor.identifier.value}\"" } else { names[0] }
}

private func schemaRenderEnum(decl: EnumDecl): Tokens {
    let name = decl.identifier.value
    let output = StringBuilder()
    for (constructor in decl.constructors) {
        if (!constructor.typeArguments.isEmpty()) {
            throw Exception("@TomlSchema enum payloads require a manual schema")
        }
    }
    schemaAppendLine(output, 0, "private func __build${name}TomlSchema(): TomlSchema {")
    schemaAppendLine(output, 1, "let __schema = TomlSchema.string()")
    for (constructor in decl.constructors) {
        schemaAppendLine(output, 1,
            "let _ = __schema.enumValue(TomlString(${schemaEnumWireExpression(constructor)}))")
    }
    schemaAppendLine(output, 1, "__schema")
    schemaAppendLine(output, 0, "}")
    let visibility = if (schemaHasModifier(decl, TokenKind.PUBLIC)) { "public " } else { "" }
    schemaAppendLine(output, 0,
        "${visibility}let ${name}TomlSchema: TomlSchema = __build${name}TomlSchema()")
    schemaAppendLine(output, 0, "extend ${name} <: TomlSchemaProvider {")
    schemaAppendLine(output, 1,
        "public static func tomlSchema(): TomlSchema { ${name}TomlSchema }")
    schemaAppendLine(output, 0, "}")
    cangjieLex(output.toString())
}

/// Derives a static schema from declared field types. Generated code depends
/// only on toml_schema public APIs and never on reflection or DataModel.
public macro TomlSchema(input: Tokens): Tokens {
    let declaration = parseDecl(input)
    let generated = match (declaration) {
        case classDecl: ClassDecl => schemaRenderRecord(classDecl, classDecl.body)
        case structDecl: StructDecl => schemaRenderRecord(structDecl, structDecl.body)
        case enumDecl: EnumDecl => schemaRenderEnum(enumDecl)
        case _ => throw Exception("@TomlSchema supports class, struct, and enum declarations")
    }
    schemaStripMetadata(input) + Token(TokenKind.NL).toTokens() + generated
}

public macro TomlSchemaName(attrs: Tokens, input: Tokens): Tokens {
    quote(@TomlSchemaNameMetadata[$attrs] $input)
}

public macro TomlSchemaIgnore(input: Tokens): Tokens {
    quote(@TomlSchemaIgnoreMetadata $input)
}

public macro TomlSchemaOptional(input: Tokens): Tokens {
    quote(@TomlSchemaOptionalMetadata $input)
}

public macro TomlSchemaNameMetadata(attrs: Tokens, input: Tokens): Tokens {
    let _ = attrs
    input
}

public macro TomlSchemaIgnoreMetadata(input: Tokens): Tokens { input }
public macro TomlSchemaOptionalMetadata(input: Tokens): Tokens { input }
