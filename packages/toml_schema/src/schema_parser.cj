// SPDX-License-Identifier: Apache-2.0
package toml_schema

import std.collection.*
import std.convert.Parsable
import std.math.numeric.BigInt
import toml.*

private class TomlSchemaParseState {
    let diagnostics = ArrayList<TomlDiagnostic>()
    let limits: TomlSchemaLimits
    var visits: Int64 = 0
    var stopped: Bool = false

    init(limits: TomlSchemaLimits) { this.limits = limits }

    func enter(path: TomlPath, depth: Int64): Bool {
        if (stopped) { return false }
        visits++
        if (visits > limits.maxVisits || depth > limits.maxDepth) {
            error("schema_budget_exceeded",
                "TOML-native schema parsing exceeded its configured budget", path)
            stopped = true
            return false
        }
        true
    }

    func error(code: String, message: String, path: TomlPath): Unit {
        if (stopped) { return }
        if (diagnostics.size + 1 >= limits.maxDiagnostics) {
            diagnostics.add(TomlDiagnostic("schema_diagnostic_limit", TomlSeverity.Error,
                "schema diagnostics reached the configured limit", path: Some(path)))
            stopped = true
            return
        }
        diagnostics.add(TomlDiagnostic(code, TomlSeverity.Error, message, path: Some(path)))
    }
}

public func parseTomlSchemaDocument(
    value: TomlValue,
    options!: TomlSchemaOptions = TomlSchemaOptions.defaults
): TomlOutcome<TomlSchemaDocument> {
    let state = TomlSchemaParseState(options.limits)
    let table = match (value) {
        case parsed: TomlTable => parsed
        case _ =>
            state.error("schema_type_mismatch", "a TOML-native schema must be a table", TomlPath())
            return TomlOutcome<TomlSchemaDocument>.Failure(state.diagnostics)
    }
    let registry = TomlSchemaRegistry()
    match (table.get("definitions")) {
        case Some(definitions: TomlTable) =>
            for (name in definitions.keys()) {
                match (definitions[name]) {
                    case definition: TomlTable =>
                        match (tomlParseSchemaTable(definition,
                            TomlPath().withKey("definitions").withKey(name), 1, state, false)) {
                            case Some(schema) =>
                                try { let _ = registry.register(name, schema) }
                                catch (_) {
                                    state.error("schema_invalid_reference",
                                        "definition '${name}' is not a valid local reference name",
                                        TomlPath().withKey("definitions").withKey(name))
                                }
                            case None => ()
                        }
                    case _ => state.error("schema_type_mismatch",
                        "each schema definition must be a table",
                        TomlPath().withKey("definitions").withKey(name))
                }
            }
        case Some(_) => state.error("schema_type_mismatch",
            "'definitions' must be a table", TomlPath().withKey("definitions"))
        case None => ()
    }
    let root = match (tomlParseSchemaTable(table, TomlPath(), 0, state, true)) {
        case Some(schema) => schema
        case None => TomlSchema.any()
    }
    if (!state.diagnostics.isEmpty()) {
        TomlOutcome<TomlSchemaDocument>.Failure(state.diagnostics)
    } else {
        TomlOutcome<TomlSchemaDocument>.Success(
            TomlSchemaDocument(root, registry), ArrayList<TomlDiagnostic>())
    }
}

private func tomlParseSchemaTable(
    table: TomlTable,
    path: TomlPath,
    depth: Int64,
    state: TomlSchemaParseState,
    allowDefinitions: Bool
): Option<TomlSchema> {
    if (!state.enter(path, depth)) { return None<TomlSchema> }
    let schema = TomlSchema.any()
    var exclusiveMinimum = false
    var exclusiveMaximum = false
    var parsedIntegerMinimum: Option<BigInt> = None<BigInt>
    var parsedIntegerMaximum: Option<BigInt> = None<BigInt>
    var parsedFloatMinimum: Option<Float64> = None<Float64>
    var parsedFloatMaximum: Option<Float64> = None<Float64>

    for (keyword in table.keys()) {
        let keywordPath = path.withKey(keyword)
        let raw = table[keyword]
        match (keyword) {
            case "type" => tomlParseSchemaTypes(raw, schema, keywordPath, state)
            case "properties" => tomlParseSchemaProperties(raw, schema, keywordPath,
                depth + 1, state)
            case "required" => tomlParseSchemaRequired(raw, schema, keywordPath, state)
            case "additionalProperties" => tomlParseAdditionalProperties(raw, schema,
                keywordPath, depth + 1, state)
            case "items" =>
                match (raw) {
                    case nested: TomlTable =>
                        match (tomlParseSchemaTable(nested, keywordPath, depth + 1, state, false)) {
                            case Some(itemSchema) => let _ = schema.items(itemSchema)
                            case None => ()
                        }
                    case _ => state.error("schema_type_mismatch", "'items' must be a table", keywordPath)
                }
            case "minimum" =>
                match (raw) {
                    case integer: TomlInteger => parsedIntegerMinimum = Some(integer.value)
                    case number: TomlFloat => parsedFloatMinimum = Some(number.value)
                    case _ => state.error("schema_type_mismatch",
                        "'minimum' must be an integer or float", keywordPath)
                }
            case "maximum" =>
                match (raw) {
                    case integer: TomlInteger => parsedIntegerMaximum = Some(integer.value)
                    case number: TomlFloat => parsedFloatMaximum = Some(number.value)
                    case _ => state.error("schema_type_mismatch",
                        "'maximum' must be an integer or float", keywordPath)
                }
            case "exclusiveMinimum" =>
                match (raw) {
                    case flag: TomlBoolean => exclusiveMinimum = flag.value
                    case _ => state.error("schema_type_mismatch",
                        "'exclusiveMinimum' must be a boolean", keywordPath)
                }
            case "exclusiveMaximum" =>
                match (raw) {
                    case flag: TomlBoolean => exclusiveMaximum = flag.value
                    case _ => state.error("schema_type_mismatch",
                        "'exclusiveMaximum' must be a boolean", keywordPath)
                }
            case "minLength" => tomlParseNonNegative(raw, keywordPath, state,
                { value => let _ = schema.minimumStringLength(value) })
            case "maxLength" => tomlParseNonNegative(raw, keywordPath, state,
                { value => let _ = schema.maximumStringLength(value) })
            case "minItems" => tomlParseNonNegative(raw, keywordPath, state,
                { value => let _ = schema.minimumItems(value) })
            case "maxItems" => tomlParseNonNegative(raw, keywordPath, state,
                { value => let _ = schema.maximumItems(value) })
            case "uniqueItems" =>
                match (raw) {
                    case flag: TomlBoolean => let _ = schema.uniqueItems(required: flag.value)
                    case _ => state.error("schema_type_mismatch", "'uniqueItems' must be a boolean", keywordPath)
                }
            case "default" => let _ = schema.withDefault(raw)
            case "const" => let _ = schema.constant(raw)
            case "enum" =>
                match (raw) {
                    case values: TomlArray =>
                        if (values.size == 0) {
                            state.error("schema_empty_enum", "'enum' must contain at least one value", keywordPath)
                        } else { let _ = schema.enumValues(values.values()) }
                    case _ => state.error("schema_type_mismatch", "'enum' must be an array", keywordPath)
                }
            case "allOf" => tomlParseSchemaBranches(raw, keywordPath, depth + 1, state,
                { branch => let _ = schema.allOf(branch) })
            case "anyOf" => tomlParseSchemaBranches(raw, keywordPath, depth + 1, state,
                { branch => let _ = schema.anyOf(branch) })
            case "oneOf" => tomlParseSchemaBranches(raw, keywordPath, depth + 1, state,
                { branch => let _ = schema.oneOf(branch) })
            case "ref" | "$ref" =>
                match (raw) {
                    case reference: TomlString =>
                        if (tomlNormalizeSchemaReference(reference.value).isSome()) {
                            let _ = schema.ref(reference.value)
                        } else {
                            state.error("schema_invalid_reference",
                                "only named local schema references are supported", keywordPath)
                        }
                    case _ => state.error("schema_type_mismatch", "schema reference must be a string", keywordPath)
                }
            case "description" =>
                match (raw) {
                    case _: TomlString => ()
                    case _ => state.error("schema_type_mismatch", "'description' must be a string", keywordPath)
                }
            case "definitions" =>
                if (!allowDefinitions) {
                    state.error("schema_unknown_keyword", "nested 'definitions' are not supported", keywordPath)
                }
            case _ => state.error("schema_unknown_keyword", "unknown schema keyword '${keyword}'", keywordPath)
        }
    }

    match (parsedIntegerMinimum) {
        case Some(value) => let _ = schema.minimumInteger(value, exclusive: exclusiveMinimum)
        case None => ()
    }
    match (parsedIntegerMaximum) {
        case Some(value) => let _ = schema.maximumInteger(value, exclusive: exclusiveMaximum)
        case None => ()
    }
    match (parsedFloatMinimum) {
        case Some(value) => let _ = schema.minimumFloat(value, exclusive: exclusiveMinimum)
        case None => ()
    }
    match (parsedFloatMaximum) {
        case Some(value) => let _ = schema.maximumFloat(value, exclusive: exclusiveMaximum)
        case None => ()
    }
    Some(schema)
}

private func tomlParseSchemaTypes(
    raw: TomlValue,
    schema: TomlSchema,
    path: TomlPath,
    state: TomlSchemaParseState
): Unit {
    match (raw) {
        case name: TomlString =>
            match (tomlParseSchemaKind(name.value)) {
                case Some(kind) => let _ = schema.allow(kind)
                case None => state.error("schema_unknown_type", "unknown TOML schema type '${name.value}'", path)
            }
        case names: TomlArray =>
            if (names.size == 0) {
                state.error("schema_empty_type", "type array must not be empty", path)
                return
            }
            for (index in 0..names.size) {
                match (names[index]) {
                    case name: TomlString =>
                        match (tomlParseSchemaKind(name.value)) {
                            case Some(kind) => let _ = schema.allow(kind)
                            case None => state.error("schema_unknown_type",
                                "unknown TOML schema type '${name.value}'", path.withIndex(index))
                        }
                    case _ => state.error("schema_type_mismatch",
                        "type array entries must be strings", path.withIndex(index))
                }
            }
        case _ => state.error("schema_type_mismatch", "'type' must be a string or array", path)
    }
}

private func tomlParseSchemaProperties(
    raw: TomlValue,
    schema: TomlSchema,
    path: TomlPath,
    depth: Int64,
    state: TomlSchemaParseState
): Unit {
    match (raw) {
        case properties: TomlTable =>
            for (name in properties.keys()) {
                match (properties[name]) {
                    case nested: TomlTable =>
                        match (tomlParseSchemaTable(nested, path.withKey(name), depth, state, false)) {
                            case Some(propertySchema) => let _ = schema.property(name, propertySchema)
                            case None => ()
                        }
                    case _ => state.error("schema_type_mismatch",
                        "property schemas must be tables", path.withKey(name))
                }
            }
        case _ => state.error("schema_type_mismatch", "'properties' must be a table", path)
    }
}

private func tomlParseSchemaRequired(
    raw: TomlValue,
    schema: TomlSchema,
    path: TomlPath,
    state: TomlSchemaParseState
): Unit {
    match (raw) {
        case values: TomlArray =>
            for (index in 0..values.size) {
                match (values[index]) {
                    case name: TomlString => let _ = schema.require(name.value)
                    case _ => state.error("schema_type_mismatch",
                        "required entries must be strings", path.withIndex(index))
                }
            }
        case _ => state.error("schema_type_mismatch", "'required' must be an array", path)
    }
}

private func tomlParseAdditionalProperties(
    raw: TomlValue,
    schema: TomlSchema,
    path: TomlPath,
    depth: Int64,
    state: TomlSchemaParseState
): Unit {
    match (raw) {
        case flag: TomlBoolean => let _ = schema.additionalProperties(flag.value)
        case nested: TomlTable =>
            match (tomlParseSchemaTable(nested, path, depth, state, false)) {
                case Some(extraSchema) => let _ = schema.additionalProperties(extraSchema)
                case None => ()
            }
        case _ => state.error("schema_type_mismatch",
            "'additionalProperties' must be a boolean or table", path)
    }
}

private func tomlParseSchemaBranches(
    raw: TomlValue,
    path: TomlPath,
    depth: Int64,
    state: TomlSchemaParseState,
    consume: (TomlSchema) -> Unit
): Unit {
    match (raw) {
        case branches: TomlArray =>
            if (branches.size == 0) {
                state.error("schema_empty_combinator", "schema combinator must not be empty", path)
                return
            }
            for (index in 0..branches.size) {
                match (branches[index]) {
                    case nested: TomlTable =>
                        match (tomlParseSchemaTable(nested, path.withIndex(index), depth, state, false)) {
                            case Some(branch) => consume(branch)
                            case None => ()
                        }
                    case _ => state.error("schema_type_mismatch",
                        "schema combinator entries must be tables", path.withIndex(index))
                }
            }
        case _ => state.error("schema_type_mismatch", "schema combinator must be an array", path)
    }
}

private func tomlParseNonNegative(
    raw: TomlValue,
    path: TomlPath,
    state: TomlSchemaParseState,
    consume: (Int64) -> Unit
): Unit {
    match (raw) {
        case integer: TomlInteger =>
            try {
                let value = Int64.parse(integer.value.toString())
                if (value < 0) {
                    state.error("schema_negative_limit", "schema size limit must be non-negative", path)
                } else { consume(value) }
            } catch (_) {
                state.error("schema_limit_out_of_range", "schema size limit does not fit Int64", path)
            }
        case _ => state.error("schema_type_mismatch", "schema size limit must be an integer", path)
    }
}

private func tomlParseSchemaKind(value: String): Option<TomlKind> {
    match (value) {
        case "string" => Some(TomlKind.String)
        case "integer" => Some(TomlKind.Integer)
        case "float" | "number" => Some(TomlKind.Float)
        case "boolean" | "bool" => Some(TomlKind.Boolean)
        case "offset-date-time" => Some(TomlKind.OffsetDateTime)
        case "local-date-time" => Some(TomlKind.LocalDateTime)
        case "local-date" => Some(TomlKind.LocalDate)
        case "local-time" => Some(TomlKind.LocalTime)
        case "array" => Some(TomlKind.Array)
        case "table" | "object" => Some(TomlKind.Table)
        case _ => None<TomlKind>
    }
}
