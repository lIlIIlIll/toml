// SPDX-License-Identifier: Apache-2.0
package toml_schema_all

import std.unittest.*
import std.unittest.testmacro.*
import toml.*
import toml_schema.*
import toml_schema_macros.*

@TomlSchema
struct TestTlsSchemaConfig {
    public let enabled: Bool
    public init(enabled: Bool) { this.enabled = enabled }
}

@TomlSchema
struct TestServiceSchemaConfig {
    @TomlSchemaName["listen_port"]
    public let port: Int64
    public let host: Option<String>
    public let tls: TestTlsSchemaConfig
    @TomlSchemaOptional
    public let mode: String
    @TomlSchemaIgnore
    public let runtimeOnly: String

    public init(
        port: Int64,
        host: Option<String>,
        tls: TestTlsSchemaConfig,
        mode: String,
        runtimeOnly: String
    ) {
        this.port = port
        this.host = host
        this.tls = tls
        this.mode = mode
        this.runtimeOnly = runtimeOnly
    }
}

@TomlSchema
enum TestSchemaMode {
    Fast | Safe
}

@TomlSchema
struct TestSchemaBox<T> {
    public let value: T
    public init(value: T) { this.value = value }
}

private func macroSchemaHasDiagnostic(
    diagnostics: Collection<TomlDiagnostic>,
    code: String
): Bool {
    for (diagnostic in diagnostics) {
        if (diagnostic.code == code) { return true }
    }
    false
}

@Test
class TomlSchemaMacroContractTests {
    // T018 -> S023
    @TestCase
    func T018_generateStaticRecordAndEnumSchemas(): Unit {
        let declared = TestServiceSchemaConfig(8080, None<String>,
            TestTlsSchemaConfig(true), "safe", "runtime")
        @Expect(declared.port, 8080)
        let valid = TomlTable()
            .put("listen_port", TomlInteger(8080))
            .put("tls", TomlTable().put("enabled", TomlBoolean(true)))
        @Expect(TestServiceSchemaConfigTomlSchema.validate(valid).isValid)
        @Expect(tomlSchemaOf<TestServiceSchemaConfig>().validate(valid).isValid)

        let missing = TestServiceSchemaConfigTomlSchema.validate(
            TomlTable().put("tls", TomlTable().put("enabled", TomlBoolean(true))))
        @Expect(!missing.isValid)
        @Expect(macroSchemaHasDiagnostic(missing.diagnostics(), "schema_required"))

        let extra = valid.deepCopy().asTable().put("runtimeOnly", TomlString("secret"))
        @Expect(macroSchemaHasDiagnostic(
            TestServiceSchemaConfigTomlSchema.validate(extra).diagnostics(),
            "schema_additional_property"))

        @Expect(TestSchemaModeTomlSchema.validate(TomlString("Fast")).isValid)
        @Expect(!TestSchemaModeTomlSchema.validate(TomlString("Unknown")).isValid)

        let boxed = TestSchemaBox(TestTlsSchemaConfig(false))
        @Expect(!boxed.value.enabled)
        let boxValue = TomlTable().put("value",
            TomlTable().put("enabled", TomlBoolean(false)))
        @Expect(TestSchemaBoxTomlSchema<TestTlsSchemaConfig>().validate(boxValue).isValid)
    }
}
