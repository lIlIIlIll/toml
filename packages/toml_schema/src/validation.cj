// SPDX-License-Identifier: Apache-2.0
package toml_schema

import std.collection.*
import toml.*

private class TomlSchemaBudget {
    let limits: TomlSchemaLimits
    var visits: Int64 = 0
    var exceeded: Bool = false
    var exceededPath: TomlPath = TomlPath()

    init(limits: TomlSchemaLimits) { this.limits = limits }

    func enter(path: TomlPath, depth: Int64, referenceDepth: Int64): Bool {
        if (exceeded) { return false }
        visits++
        if (visits > limits.maxVisits || depth > limits.maxDepth ||
            referenceDepth > limits.maxReferenceDepth) {
            exceeded = true
            exceededPath = TomlPath(path.segments())
            return false
        }
        true
    }
}

private class TomlSchemaState {
    let limits: TomlSchemaLimits
    let diagnostics = ArrayList<TomlDiagnostic>()
    private var truncated: Bool = false

    init(limits: TomlSchemaLimits) { this.limits = limits }

    func error(code: String, message: String, path: TomlPath): Unit {
        if (truncated) { return }
        if (diagnostics.size + 1 >= limits.maxDiagnostics) {
            diagnostics.add(TomlDiagnostic("schema_diagnostic_limit", TomlSeverity.Error,
                "schema diagnostics reached the configured limit", path: Some(path)))
            truncated = true
            return
        }
        diagnostics.add(TomlDiagnostic(code, TomlSeverity.Error, message, path: Some(path)))
    }
}

public func validateTomlSchema(
    schema: TomlSchema,
    value: TomlValue,
    registry!: TomlSchemaRegistry = TomlSchemaRegistry.empty,
    options!: TomlSchemaOptions = TomlSchemaOptions.defaults
): TomlSchemaValidation {
    let state = TomlSchemaState(options.limits)
    let budget = TomlSchemaBudget(options.limits)
    tomlValidateSchemaNode(schema, value, TomlPath(), 0, 0, registry, state, budget)
    if (budget.exceeded) {
        state.error("schema_budget_exceeded",
            "schema validation exceeded its depth, visit, or reference budget", budget.exceededPath)
    }
    TomlSchemaValidation(state.diagnostics)
}

private func tomlValidateSchemaNode(
    schema: TomlSchema,
    value: TomlValue,
    path: TomlPath,
    depth: Int64,
    referenceDepth: Int64,
    registry: TomlSchemaRegistry,
    state: TomlSchemaState,
    budget: TomlSchemaBudget
): Unit {
    if (!budget.enter(path, depth, referenceDepth)) { return }

    match (schema.referenceValue()) {
        case Some(reference) =>
            match (registry.resolve(reference)) {
                case Some(target) =>
                    tomlValidateSchemaNode(target, value, path, depth + 1,
                        referenceDepth + 1, registry, state, budget)
                case None => state.error("schema_unknown_reference",
                    "unknown or non-local schema reference '${reference}'", path)
            }
        case None => ()
    }

    let accepted = schema.acceptedKinds()
    if (!accepted.isEmpty() && !tomlSchemaAcceptsKind(accepted, value.kind())) {
        state.error("schema_type_mismatch",
            "expected ${tomlSchemaKindList(accepted)}, found ${tomlSchemaKindName(value.kind())}", path)
        return
    }

    match (schema.constantValue()) {
        case Some(expected) =>
            if (!value.equivalentTo(expected)) {
                state.error("schema_const", "value does not match the required constant", path)
            }
        case None => ()
    }

    let enumValues = schema.enumSnapshots()
    if (!enumValues.isEmpty()) {
        var matched = false
        for (candidate in enumValues) {
            if (value.equivalentTo(candidate.thaw())) { matched = true; break }
        }
        if (!matched) { state.error("schema_enum", "value is not one of the allowed values", path) }
    }

    match (value) {
        case integer: TomlInteger => tomlValidateSchemaInteger(schema, integer, path, state)
        case number: TomlFloat => tomlValidateSchemaFloat(schema, number, path, state)
        case stringValue: TomlString => tomlValidateSchemaString(schema, stringValue, path, state)
        case array: TomlArray =>
            tomlValidateSchemaArray(schema, array, path, depth, referenceDepth,
                registry, state, budget)
        case table: TomlTable =>
            tomlValidateSchemaTable(schema, table, path, depth, referenceDepth,
                registry, state, budget)
        case _ => ()
    }

    for (branch in schema.allOfBranches()) {
        tomlValidateSchemaNode(branch, value, path, depth + 1, referenceDepth,
            registry, state, budget)
    }

    let any = schema.anyOfBranches()
    if (!any.isEmpty()) {
        var matched = false
        for (branch in any) {
            if (tomlSchemaBranchMatches(branch, value, path, depth + 1,
                referenceDepth, registry, budget, state.limits)) {
                matched = true
                break
            }
        }
        if (!matched) { state.error("schema_any_of", "value does not match any allowed schema", path) }
    }

    let one = schema.oneOfBranches()
    if (!one.isEmpty()) {
        var matches: Int64 = 0
        for (branch in one) {
            if (tomlSchemaBranchMatches(branch, value, path, depth + 1,
                referenceDepth, registry, budget, state.limits)) { matches++ }
        }
        if (matches != 1) {
            state.error("schema_one_of", "value must match exactly one schema, but matched ${matches}", path)
        }
    }
}

private func tomlSchemaBranchMatches(
    schema: TomlSchema,
    value: TomlValue,
    path: TomlPath,
    depth: Int64,
    referenceDepth: Int64,
    registry: TomlSchemaRegistry,
    budget: TomlSchemaBudget,
    limits: TomlSchemaLimits
): Bool {
    let probe = TomlSchemaState(limits)
    tomlValidateSchemaNode(schema, value, path, depth, referenceDepth,
        registry, probe, budget)
    !budget.exceeded && probe.diagnostics.isEmpty()
}

private func tomlValidateSchemaInteger(
    schema: TomlSchema,
    value: TomlInteger,
    path: TomlPath,
    state: TomlSchemaState
): Unit {
    match (schema.integerMinimum()) {
        case Some(bound) =>
            let invalid = if (schema.isIntegerMinimumExclusive()) {
                value.value <= bound
            } else { value.value < bound }
            if (invalid) { state.error("schema_minimum", "integer is below its minimum", path) }
        case None => ()
    }
    match (schema.integerMaximum()) {
        case Some(bound) =>
            let invalid = if (schema.isIntegerMaximumExclusive()) {
                value.value >= bound
            } else { value.value > bound }
            if (invalid) { state.error("schema_maximum", "integer is above its maximum", path) }
        case None => ()
    }
}

private func tomlValidateSchemaFloat(
    schema: TomlSchema,
    value: TomlFloat,
    path: TomlPath,
    state: TomlSchemaState
): Unit {
    if (value.value.isNaN() &&
        (schema.floatMinimum().isSome() || schema.floatMaximum().isSome())) {
        state.error("schema_number_nan", "NaN cannot satisfy an ordered numeric bound", path)
        return
    }
    match (schema.floatMinimum()) {
        case Some(bound) =>
            let invalid = if (schema.isFloatMinimumExclusive()) {
                value.value <= bound
            } else { value.value < bound }
            if (invalid) { state.error("schema_minimum", "float is below its minimum", path) }
        case None => ()
    }
    match (schema.floatMaximum()) {
        case Some(bound) =>
            let invalid = if (schema.isFloatMaximumExclusive()) {
                value.value >= bound
            } else { value.value > bound }
            if (invalid) { state.error("schema_maximum", "float is above its maximum", path) }
        case None => ()
    }
}

private func tomlValidateSchemaString(
    schema: TomlSchema,
    value: TomlString,
    path: TomlPath,
    state: TomlSchemaState
): Unit {
    var length: Int64 = 0
    for (_ in value.value.runes()) { length++ }
    match (schema.stringMinimum()) {
        case Some(bound) =>
            if (length < bound) {
                state.error("schema_min_length", "string has ${length} scalars; minimum is ${bound}", path)
            }
        case None => ()
    }
    match (schema.stringMaximum()) {
        case Some(bound) =>
            if (length > bound) {
                state.error("schema_max_length", "string has ${length} scalars; maximum is ${bound}", path)
            }
        case None => ()
    }
}

private func tomlValidateSchemaArray(
    schema: TomlSchema,
    value: TomlArray,
    path: TomlPath,
    depth: Int64,
    referenceDepth: Int64,
    registry: TomlSchemaRegistry,
    state: TomlSchemaState,
    budget: TomlSchemaBudget
): Unit {
    match (schema.arrayMinimum()) {
        case Some(bound) =>
            if (value.size < bound) {
                state.error("schema_min_items", "array has ${value.size} items; minimum is ${bound}", path)
            }
        case None => ()
    }
    match (schema.arrayMaximum()) {
        case Some(bound) =>
            if (value.size > bound) {
                state.error("schema_max_items", "array has ${value.size} items; maximum is ${bound}", path)
            }
        case None => ()
    }
    if (schema.requiresUniqueItems()) {
        for (left in 0..value.size) {
            for (right in left + 1..value.size) {
                if (!budget.enter(path.withIndex(right), depth + 1, referenceDepth)) { return }
                if (value[left].equivalentTo(value[right])) {
                    state.error("schema_unique_items",
                        "array items ${left} and ${right} are equivalent", path.withIndex(right))
                }
            }
        }
    }
    match (schema.itemSchema()) {
        case Some(itemSchema) =>
            for (index in 0..value.size) {
                tomlValidateSchemaNode(itemSchema, value[index], path.withIndex(index),
                    depth + 1, referenceDepth, registry, state, budget)
            }
        case None => ()
    }
}

private func tomlValidateSchemaTable(
    schema: TomlSchema,
    value: TomlTable,
    path: TomlPath,
    depth: Int64,
    referenceDepth: Int64,
    registry: TomlSchemaRegistry,
    state: TomlSchemaState,
    budget: TomlSchemaBudget
): Unit {
    for (name in schema.required()) {
        if (!value.contains(name)) {
            state.error("schema_required", "required property '${name}' is missing", path.withKey(name))
        }
    }
    for (name in value.keys()) {
        match (schema.property(name)) {
            case Some(propertySchema) =>
                tomlValidateSchemaNode(propertySchema, value[name], path.withKey(name),
                    depth + 1, referenceDepth, registry, state, budget)
            case None =>
                match (schema.extraSchema()) {
                    case Some(extraSchema) =>
                        tomlValidateSchemaNode(extraSchema, value[name], path.withKey(name),
                            depth + 1, referenceDepth, registry, state, budget)
                    case None =>
                        if (!schema.extrasAllowed()) {
                            state.error("schema_additional_property",
                                "additional property '${name}' is not allowed", path.withKey(name))
                        }
                }
        }
    }
}

public func applyTomlSchemaDefaults(
    schema: TomlSchema,
    value: TomlValue,
    registry!: TomlSchemaRegistry = TomlSchemaRegistry.empty,
    options!: TomlSchemaOptions = TomlSchemaOptions.defaults
): TomlOutcome<TomlValue> {
    try {
        let copy = value.deepCopy()
        let budget = TomlSchemaBudget(options.limits)
        tomlApplySchemaDefaultsNode(schema, copy, TomlPath(), 0, 0, registry, budget)
        if (budget.exceeded) {
            let diagnostics = ArrayList<TomlDiagnostic>()
            diagnostics.add(TomlDiagnostic("schema_budget_exceeded", TomlSeverity.Error,
                "schema default application exceeded its configured budget",
                path: Some(budget.exceededPath)))
            return TomlOutcome<TomlValue>.Failure(diagnostics)
        }
        let validation = validateTomlSchema(schema, copy, registry: registry, options: options)
        if (!validation.isValid) {
            return TomlOutcome<TomlValue>.Failure(validation.diagnostics())
        }
        TomlOutcome<TomlValue>.Success(copy, ArrayList<TomlDiagnostic>())
    } catch (exception: Exception) {
        let diagnostics = ArrayList<TomlDiagnostic>()
        diagnostics.add(TomlDiagnostic("schema_default_copy", TomlSeverity.Error,
            "failed to materialize schema defaults: ${exception.message}"))
        TomlOutcome<TomlValue>.Failure(diagnostics)
    }
}

private func tomlApplySchemaDefaultsNode(
    schema: TomlSchema,
    value: TomlValue,
    path: TomlPath,
    depth: Int64,
    referenceDepth: Int64,
    registry: TomlSchemaRegistry,
    budget: TomlSchemaBudget
): Unit {
    if (!budget.enter(path, depth, referenceDepth)) { return }
    match (schema.referenceValue()) {
        case Some(reference) =>
            match (registry.resolve(reference)) {
                case Some(target) => tomlApplySchemaDefaultsNode(target, value, path,
                    depth + 1, referenceDepth + 1, registry, budget)
                case None => ()
            }
        case None => ()
    }
    match (value) {
        case table: TomlTable =>
            for (name in schema.properties()) {
                match ((table.get(name), schema.property(name))) {
                    case (None, Some(childSchema)) =>
                        match (childSchema.defaultValue()) {
                            case Some(defaultValue) =>
                                table.put(name, defaultValue)
                                tomlApplySchemaDefaultsNode(childSchema, table[name], path.withKey(name),
                                    depth + 1, referenceDepth, registry, budget)
                            case None => ()
                        }
                    case (Some(child), Some(childSchema)) =>
                        tomlApplySchemaDefaultsNode(childSchema, child, path.withKey(name),
                            depth + 1, referenceDepth, registry, budget)
                    case _ => ()
                }
            }
            match (schema.extraSchema()) {
                case Some(extraSchema) =>
                    for (name in table.keys()) {
                        if (schema.property(name).isNone()) {
                            tomlApplySchemaDefaultsNode(extraSchema, table[name], path.withKey(name),
                                depth + 1, referenceDepth, registry, budget)
                        }
                    }
                case None => ()
            }
        case array: TomlArray =>
            match (schema.itemSchema()) {
                case Some(itemSchema) =>
                    for (index in 0..array.size) {
                        tomlApplySchemaDefaultsNode(itemSchema, array[index], path.withIndex(index),
                            depth + 1, referenceDepth, registry, budget)
                    }
                case None => ()
            }
        case _ => ()
    }
    for (branch in schema.allOfBranches()) {
        tomlApplySchemaDefaultsNode(branch, value, path, depth + 1,
            referenceDepth, registry, budget)
    }
    let any = schema.anyOfBranches()
    for (branch in any) {
        if (tomlSchemaDefaultsBranchMatches(branch, value, path, depth + 1,
            referenceDepth, registry, budget)) {
            tomlApplySchemaDefaultsNode(branch, value, path, depth + 1,
                referenceDepth, registry, budget)
            break
        }
    }
    let one = schema.oneOfBranches()
    var selected: Option<TomlSchema> = None<TomlSchema>
    var matches: Int64 = 0
    for (branch in one) {
        if (tomlSchemaDefaultsBranchMatches(branch, value, path, depth + 1,
            referenceDepth, registry, budget)) {
            selected = Some(branch)
            matches++
        }
    }
    if (matches == 1) {
        match (selected) {
            case Some(branch) => tomlApplySchemaDefaultsNode(branch, value, path,
                depth + 1, referenceDepth, registry, budget)
            case None => ()
        }
    }
}

private func tomlSchemaDefaultsBranchMatches(
    schema: TomlSchema,
    value: TomlValue,
    path: TomlPath,
    depth: Int64,
    referenceDepth: Int64,
    registry: TomlSchemaRegistry,
    budget: TomlSchemaBudget
): Bool {
    let state = TomlSchemaState(budget.limits)
    tomlValidateSchemaNode(schema, value, path, depth, referenceDepth,
        registry, state, budget)
    !budget.exceeded && state.diagnostics.isEmpty()
}

private func tomlSchemaAcceptsKind(accepted: Collection<TomlKind>, actual: TomlKind): Bool {
    for (kind in accepted) { if (tomlSchemaKindsEqual(kind, actual)) { return true } }
    false
}

private func tomlSchemaKindList(kinds: Collection<TomlKind>): String {
    let output = StringBuilder()
    var first = true
    for (kind in kinds) {
        if (!first) { output.append(" or ") }
        output.append(tomlSchemaKindName(kind))
        first = false
    }
    output.toString()
}

func tomlSchemaKindName(kind: TomlKind): String {
    match (kind) {
        case TomlKind.String => "string"
        case TomlKind.Integer => "integer"
        case TomlKind.Float => "float"
        case TomlKind.Boolean => "boolean"
        case TomlKind.OffsetDateTime => "offset-date-time"
        case TomlKind.LocalDateTime => "local-date-time"
        case TomlKind.LocalDate => "local-date"
        case TomlKind.LocalTime => "local-time"
        case TomlKind.Array => "array"
        case TomlKind.Table => "table"
    }
}
