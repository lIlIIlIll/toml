// SPDX-License-Identifier: Apache-2.0
package toml_schema

import std.collection.*
import std.math.numeric.BigInt
import toml.*

/// Hard limits shared by validation, combinator probing, local references and
/// default materialization.
public class TomlSchemaLimits {
    public let maxDepth: Int64
    public let maxVisits: Int64
    public let maxDiagnostics: Int64
    public let maxReferenceDepth: Int64

    public init(
        maxDepth!: Int64 = 128,
        maxVisits!: Int64 = 100_000,
        maxDiagnostics!: Int64 = 100,
        maxReferenceDepth!: Int64 = 64
    ) {
        if (maxDepth <= 0 || maxVisits <= 0 || maxDiagnostics <= 0 ||
            maxReferenceDepth <= 0) {
            throw IllegalArgumentException("all TOML schema limits must be positive")
        }
        this.maxDepth = maxDepth
        this.maxVisits = maxVisits
        this.maxDiagnostics = maxDiagnostics
        this.maxReferenceDepth = maxReferenceDepth
    }

    public static let defaults: TomlSchemaLimits = TomlSchemaLimits()
}

public class TomlSchemaOptions {
    public let limits: TomlSchemaLimits

    public init(limits!: TomlSchemaLimits = TomlSchemaLimits.defaults) {
        this.limits = limits
    }

    public static let defaults: TomlSchemaOptions = TomlSchemaOptions()
}

/// Explicit provider used by generated schema code. There is no runtime
/// registry or reflection lookup.
public interface TomlSchemaProvider {
    static func tomlSchema(): TomlSchema
}

public func tomlSchemaOf<T>(): TomlSchema where T <: TomlSchemaProvider {
    T.tomlSchema()
}

/// Mutable programmatic schema builder. Once shared for validation, callers
/// should treat the instance and every nested instance as read-only.
public class TomlSchema {
    private let kinds = ArrayList<TomlKind>()
    private let propertyOrder = ArrayList<String>()
    private let propertySchemas = HashMap<String, TomlSchema>()
    private let requiredProperties = ArrayList<String>()
    private let enumeratedValues = ArrayList<FrozenTomlValue>()
    private let allBranches = ArrayList<TomlSchema>()
    private let anyBranches = ArrayList<TomlSchema>()
    private let oneBranches = ArrayList<TomlSchema>()

    private var itemRule: Option<TomlSchema> = None<TomlSchema>
    private var additionalRule: Option<TomlSchema> = None<TomlSchema>
    private var allowAdditional: Bool = true
    private var defaultSnapshot: Option<FrozenTomlValue> = None<FrozenTomlValue>
    private var constantSnapshot: Option<FrozenTomlValue> = None<FrozenTomlValue>
    private var localReference: Option<String> = None<String>

    private var integerMin: Option<BigInt> = None<BigInt>
    private var integerMax: Option<BigInt> = None<BigInt>
    private var floatMin: Option<Float64> = None<Float64>
    private var floatMax: Option<Float64> = None<Float64>
    private var integerMinExclusive: Bool = false
    private var integerMaxExclusive: Bool = false
    private var floatMinExclusive: Bool = false
    private var floatMaxExclusive: Bool = false
    private var stringMin: Option<Int64> = None<Int64>
    private var stringMax: Option<Int64> = None<Int64>
    private var arrayMin: Option<Int64> = None<Int64>
    private var arrayMax: Option<Int64> = None<Int64>
    private var uniqueArrayItems: Bool = false

    public init() {}

    public init(kind: TomlKind) { kinds.add(kind) }

    public static func any(): TomlSchema { TomlSchema() }
    public static func string(): TomlSchema { TomlSchema(TomlKind.String) }
    public static func integer(): TomlSchema { TomlSchema(TomlKind.Integer) }
    public static func float(): TomlSchema { TomlSchema(TomlKind.Float) }
    public static func boolean(): TomlSchema { TomlSchema(TomlKind.Boolean) }
    public static func offsetDateTime(): TomlSchema { TomlSchema(TomlKind.OffsetDateTime) }
    public static func localDateTime(): TomlSchema { TomlSchema(TomlKind.LocalDateTime) }
    public static func localDate(): TomlSchema { TomlSchema(TomlKind.LocalDate) }
    public static func localTime(): TomlSchema { TomlSchema(TomlKind.LocalTime) }
    public static func array(): TomlSchema { TomlSchema(TomlKind.Array) }
    public static func array(items: TomlSchema): TomlSchema {
        TomlSchema(TomlKind.Array).items(items)
    }
    public static func table(): TomlSchema { TomlSchema(TomlKind.Table) }
    public static func reference(reference: String): TomlSchema {
        TomlSchema().ref(reference)
    }

    public func allow(kind: TomlKind): TomlSchema {
        for (existing in kinds) { if (tomlSchemaKindsEqual(existing, kind)) { return this } }
        kinds.add(kind)
        this
    }

    public func property(
        name: String,
        schema: TomlSchema,
        required!: Bool = false
    ): TomlSchema {
        if (!propertySchemas.contains(name)) { propertyOrder.add(name) }
        let _ = propertySchemas.add(name, schema)
        if (required) { let _ = require(name) }
        this
    }

    public func require(name: String): TomlSchema {
        for (existing in requiredProperties) { if (existing == name) { return this } }
        requiredProperties.add(name)
        this
    }

    public func additionalProperties(allowed: Bool): TomlSchema {
        allowAdditional = allowed
        if (!allowed) { additionalRule = None<TomlSchema> }
        this
    }

    public func additionalProperties(schema: TomlSchema): TomlSchema {
        allowAdditional = true
        additionalRule = Some(schema)
        this
    }

    public func items(schema: TomlSchema): TomlSchema {
        itemRule = Some(schema)
        this
    }

    public func withDefault(value: TomlValue): TomlSchema {
        defaultSnapshot = Some(value.freeze())
        this
    }

    public func constant(value: TomlValue): TomlSchema {
        constantSnapshot = Some(value.freeze())
        this
    }

    public func enumValue(value: TomlValue): TomlSchema {
        enumeratedValues.add(value.freeze())
        this
    }

    public func enumValues(values: Collection<TomlValue>): TomlSchema {
        for (value in values) { enumeratedValues.add(value.freeze()) }
        this
    }

    public func minimumInteger(value: BigInt, exclusive!: Bool = false): TomlSchema {
        integerMin = Some(value)
        integerMinExclusive = exclusive
        this
    }

    public func maximumInteger(value: BigInt, exclusive!: Bool = false): TomlSchema {
        integerMax = Some(value)
        integerMaxExclusive = exclusive
        this
    }

    public func minimumFloat(value: Float64, exclusive!: Bool = false): TomlSchema {
        floatMin = Some(value)
        floatMinExclusive = exclusive
        this
    }

    public func maximumFloat(value: Float64, exclusive!: Bool = false): TomlSchema {
        floatMax = Some(value)
        floatMaxExclusive = exclusive
        this
    }

    public func minimumStringLength(value: Int64): TomlSchema {
        schemaNonNegative("minimum string length", value)
        stringMin = Some(value)
        this
    }

    public func maximumStringLength(value: Int64): TomlSchema {
        schemaNonNegative("maximum string length", value)
        stringMax = Some(value)
        this
    }

    public func minimumItems(value: Int64): TomlSchema {
        schemaNonNegative("minimum item count", value)
        arrayMin = Some(value)
        this
    }

    public func maximumItems(value: Int64): TomlSchema {
        schemaNonNegative("maximum item count", value)
        arrayMax = Some(value)
        this
    }

    public func uniqueItems(required!: Bool = true): TomlSchema {
        uniqueArrayItems = required
        this
    }

    public func allOf(schema: TomlSchema): TomlSchema { allBranches.add(schema); this }
    public func anyOf(schema: TomlSchema): TomlSchema { anyBranches.add(schema); this }
    public func oneOf(schema: TomlSchema): TomlSchema { oneBranches.add(schema); this }

    public func ref(reference: String): TomlSchema {
        if (reference.isEmpty()) { throw IllegalArgumentException("schema reference must not be empty") }
        localReference = Some(reference)
        this
    }

    public func validate(
        value: TomlValue,
        registry!: TomlSchemaRegistry = TomlSchemaRegistry.empty,
        options!: TomlSchemaOptions = TomlSchemaOptions.defaults
    ): TomlSchemaValidation {
        validateTomlSchema(this, value, registry: registry, options: options)
    }

    /// Returns a detached copy with defaults inserted. The input is never
    /// mutated, including when validation fails.
    public func validateAndApplyDefaults(
        value: TomlValue,
        registry!: TomlSchemaRegistry = TomlSchemaRegistry.empty,
        options!: TomlSchemaOptions = TomlSchemaOptions.defaults
    ): TomlOutcome<TomlValue> {
        applyTomlSchemaDefaults(this, value, registry: registry, options: options)
    }

    func acceptedKinds(): ArrayList<TomlKind> { kinds.clone() }
    func properties(): ArrayList<String> { propertyOrder.clone() }
    func property(name: String): Option<TomlSchema> { propertySchemas.get(name) }
    func required(): ArrayList<String> { requiredProperties.clone() }
    func extrasAllowed(): Bool { allowAdditional }
    func extraSchema(): Option<TomlSchema> { additionalRule }
    func itemSchema(): Option<TomlSchema> { itemRule }
    func defaultValue(): Option<TomlValue> {
        match (defaultSnapshot) {
            case Some(value) => Some(value.thaw())
            case None => None<TomlValue>
        }
    }
    func constantValue(): Option<TomlValue> {
        match (constantSnapshot) {
            case Some(value) => Some(value.thaw())
            case None => None<TomlValue>
        }
    }
    func enumSnapshots(): ArrayList<FrozenTomlValue> { enumeratedValues.clone() }
    func allOfBranches(): ArrayList<TomlSchema> { allBranches.clone() }
    func anyOfBranches(): ArrayList<TomlSchema> { anyBranches.clone() }
    func oneOfBranches(): ArrayList<TomlSchema> { oneBranches.clone() }
    func referenceValue(): Option<String> { localReference }
    func integerMinimum(): Option<BigInt> { integerMin }
    func integerMaximum(): Option<BigInt> { integerMax }
    func floatMinimum(): Option<Float64> { floatMin }
    func floatMaximum(): Option<Float64> { floatMax }
    func isIntegerMinimumExclusive(): Bool { integerMinExclusive }
    func isIntegerMaximumExclusive(): Bool { integerMaxExclusive }
    func isFloatMinimumExclusive(): Bool { floatMinExclusive }
    func isFloatMaximumExclusive(): Bool { floatMaxExclusive }
    func stringMinimum(): Option<Int64> { stringMin }
    func stringMaximum(): Option<Int64> { stringMax }
    func arrayMinimum(): Option<Int64> { arrayMin }
    func arrayMaximum(): Option<Int64> { arrayMax }
    func requiresUniqueItems(): Bool { uniqueArrayItems }
}

/// Named local definitions. External URLs and file references are rejected.
public class TomlSchemaRegistry {
    private let definitions = HashMap<String, TomlSchema>()
    private let definitionOrder = ArrayList<String>()

    public init() {}

    public func register(name: String, schema: TomlSchema): TomlSchemaRegistry {
        let normalized = tomlNormalizeSchemaReference(name)
        match (normalized) {
            case Some(key) =>
                if (!definitions.contains(key)) { definitionOrder.add(key) }
                let _ = definitions.add(key, schema)
            case None => throw IllegalArgumentException("schema definitions require a local name")
        }
        this
    }

    public func contains(name: String): Bool {
        match (tomlNormalizeSchemaReference(name)) {
            case Some(key) => definitions.contains(key)
            case None => false
        }
    }

    public func resolve(reference: String): Option<TomlSchema> {
        match (tomlNormalizeSchemaReference(reference)) {
            case Some(key) => definitions.get(key)
            case None => None<TomlSchema>
        }
    }

    public func names(): ArrayList<String> {
        definitionOrder.clone()
    }

    public static let empty: TomlSchemaRegistry = TomlSchemaRegistry()
}

public class TomlSchemaValidation {
    private let reported: ArrayList<TomlDiagnostic>

    init(diagnostics: Collection<TomlDiagnostic>) {
        reported = ArrayList<TomlDiagnostic>(diagnostics)
    }

    public prop isValid: Bool { get() { reported.isEmpty() } }
    public func diagnostics(): ArrayList<TomlDiagnostic> { reported.clone() }
}

/// Parsed TOML-native schema plus its local definitions.
public class TomlSchemaDocument {
    public let root: TomlSchema
    public let registry: TomlSchemaRegistry

    init(root: TomlSchema, registry: TomlSchemaRegistry) {
        this.root = root
        this.registry = registry
    }

    public static func fromToml(
        value: TomlValue,
        options!: TomlSchemaOptions = TomlSchemaOptions.defaults
    ): TomlOutcome<TomlSchemaDocument> {
        parseTomlSchemaDocument(value, options: options)
    }

    public func validate(
        value: TomlValue,
        options!: TomlSchemaOptions = TomlSchemaOptions.defaults
    ): TomlSchemaValidation {
        root.validate(value, registry: registry, options: options)
    }

    public func validateAndApplyDefaults(
        value: TomlValue,
        options!: TomlSchemaOptions = TomlSchemaOptions.defaults
    ): TomlOutcome<TomlValue> {
        root.validateAndApplyDefaults(value, registry: registry, options: options)
    }
}

private func schemaNonNegative(name: String, value: Int64): Unit {
    if (value < 0) { throw IllegalArgumentException("${name} must be non-negative") }
}

func tomlNormalizeSchemaReference(reference: String): Option<String> {
    let value = reference.trimAscii()
    if (value.isEmpty() || value.contains("://") || value.startsWith("file:")) {
        return None<String>
    }
    if (value.startsWith("#/definitions/") && value.size > 14) {
        return Some(value[14..value.size])
    }
    if (value.startsWith("#/$defs/") && value.size > 8) {
        return Some(value[8..value.size])
    }
    if (value.startsWith("#") || value.contains("/")) { return None<String> }
    Some(value)
}

func tomlSchemaKindsEqual(left: TomlKind, right: TomlKind): Bool {
    match ((left, right)) {
        case (TomlKind.String, TomlKind.String) => true
        case (TomlKind.Integer, TomlKind.Integer) => true
        case (TomlKind.Float, TomlKind.Float) => true
        case (TomlKind.Boolean, TomlKind.Boolean) => true
        case (TomlKind.OffsetDateTime, TomlKind.OffsetDateTime) => true
        case (TomlKind.LocalDateTime, TomlKind.LocalDateTime) => true
        case (TomlKind.LocalDate, TomlKind.LocalDate) => true
        case (TomlKind.LocalTime, TomlKind.LocalTime) => true
        case (TomlKind.Array, TomlKind.Array) => true
        case (TomlKind.Table, TomlKind.Table) => true
        case _ => false
    }
}
