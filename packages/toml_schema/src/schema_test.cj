// SPDX-License-Identifier: Apache-2.0
package toml_schema

import std.math.numeric.BigInt
import std.unittest.*
import std.unittest.testmacro.*
import toml.*

private func schemaHasDiagnostic(diagnostics: Collection<TomlDiagnostic>, code: String): Bool {
    for (diagnostic in diagnostics) {
        if (diagnostic.code == code) { return true }
    }
    false
}

@Test
class TomlSchemaContractTests {
    // T015 -> S018/S019
    @TestCase
    func T015_validateProgrammaticConstraintsAndDetachedDefaults(): Unit {
        let tags = TomlSchema.array(TomlSchema.string())
            .withDefault(TomlArray().add(TomlString("base")))
        let schema = TomlSchema.table()
            .property("port", TomlSchema.integer()
                .minimumInteger(BigInt(1)).maximumInteger(BigInt(65535)), required: true)
            .property("tags", tags)
            .additionalProperties(false)

        let input = TomlTable().put("port", TomlInteger(8080))
        @Expect(schema.validate(input).isValid)
        let first = schema.validateAndApplyDefaults(input).getOrThrow().asTable()
        let second = schema.validateAndApplyDefaults(input).getOrThrow().asTable()
        @Expect(first["tags"].asArray()[0].asString().value, "base")
        first["tags"].asArray().add(TomlString("changed"))
        @Expect(second["tags"].asArray().size, 1)
        @Expect(!input.contains("tags"))

        let missing = schema.validate(TomlTable())
        @Expect(!missing.isValid)
        @Expect(schemaHasDiagnostic(missing.diagnostics(), "schema_required"))

        let extra = schema.validate(TomlTable()
            .put("port", TomlInteger(8080)).put("debug", TomlBoolean(true)))
        @Expect(!extra.isValid)
        @Expect(schemaHasDiagnostic(extra.diagnostics(), "schema_additional_property"))

        let outOfRange = schema.validate(TomlTable().put("port", TomlInteger(70000)))
        @Expect(schemaHasDiagnostic(outOfRange.diagnostics(), "schema_maximum"))
    }

    // T016 -> S020/S021
    @TestCase
    func T016_validateArraysCombinatorsReferencesAndBudgets(): Unit {
        let arraySchema = TomlSchema.array(TomlSchema.integer()
            .minimumInteger(BigInt(0)))
            .minimumItems(2).maximumItems(3).uniqueItems()
        @Expect(arraySchema.validate(TomlArray()
            .add(TomlInteger(1)).add(TomlInteger(2))).isValid)
        let duplicate = arraySchema.validate(TomlArray()
            .add(TomlInteger(1)).add(TomlInteger(1)))
        @Expect(schemaHasDiagnostic(duplicate.diagnostics(), "schema_unique_items"))

        let registry = TomlSchemaRegistry()
            .register("positive", TomlSchema.integer().minimumInteger(BigInt(1)))
        let referenced = TomlSchema.reference("#/definitions/positive")
        @Expect(referenced.validate(TomlInteger(1), registry: registry).isValid)
        @Expect(!referenced.validate(TomlInteger(0), registry: registry).isValid)

        let choice = TomlSchema.any()
            .anyOf(TomlSchema.string().minimumStringLength(1))
            .anyOf(TomlSchema.integer().minimumInteger(BigInt(1)))
        @Expect(choice.validate(TomlString("ok")).isValid)
        @Expect(!choice.validate(TomlBoolean(false)).isValid)

        let ambiguous = TomlSchema.any()
            .oneOf(TomlSchema.any())
            .oneOf(TomlSchema.integer())
        let ambiguity = ambiguous.validate(TomlInteger(1))
        @Expect(schemaHasDiagnostic(ambiguity.diagnostics(), "schema_one_of"))

        let loop = TomlSchema.reference("loop")
        let loopRegistry = TomlSchemaRegistry().register("loop", loop)
        let limited = loop.validate(TomlInteger(1), registry: loopRegistry,
            options: TomlSchemaOptions(limits: TomlSchemaLimits(maxReferenceDepth: 3)))
        @Expect(schemaHasDiagnostic(limited.diagnostics(), "schema_budget_exceeded"))
    }

    // T017 -> S022
    @TestCase
    func T017_parseTomlNativeSchemaAndRejectRemoteReferences(): Unit {
        let schemaSource = """
        type = "table"
        required = ["port"]
        additionalProperties = false

        [properties.port]
        ref = "#/definitions/positive"

        [properties.host]
        type = "string"
        minLength = 1
        default = "localhost"

        [definitions.positive]
        type = "integer"
        minimum = 1
        maximum = 65535
        """
        let schemaValue = parseToml(schemaSource).getOrThrow()
        let document = TomlSchemaDocument.fromToml(schemaValue).getOrThrow()
        let input = parseToml("port = 8080\n").getOrThrow()
        @Expect(document.validate(input).isValid)
        let defaulted = document.validateAndApplyDefaults(input).getOrThrow().asTable()
        @Expect(defaulted["host"].asString().value, "localhost")
        @Expect(!input.contains("host"))

        let invalidPort = document.validate(parseToml("port = 0\n").getOrThrow())
        @Expect(schemaHasDiagnostic(invalidPort.diagnostics(), "schema_minimum"))

        let remote = TomlTable().put("ref", TomlString("https://example.invalid/schema"))
        let rejected = TomlSchemaDocument.fromToml(remote)
        @Expect(!rejected.isSuccess())
        @Expect(schemaHasDiagnostic(rejected.diagnostics(), "schema_invalid_reference"))
    }
}
