// SPDX-License-Identifier: Apache-2.0
package toml_all

import toml.*
import toml_macros.*

import std.collection.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@TomlCodec
struct TestCodecProfile {
    @TomlName["user_name"]
    public let name: String
    public let age: Int64
    public let nick: Option<String>

    public init(name: String, age: Int64, nick: Option<String>) {
        this.name = name
        this.age = age
        this.nick = nick
    }
}

@TomlCodec
struct TestCodecIdentity {
    public let id: Int64
    public init(id: Int64) { this.id = id }
}

@TomlCodec
struct TestCodecEnvelope {
    @TomlFlatten
    public let identity: TestCodecIdentity
    public let enabled: Bool

    public init(identity: TestCodecIdentity, enabled: Bool) {
        this.identity = identity
        this.enabled = enabled
    }
}

@TomlCodec
enum TestCodecMode {
    Fast | Safe
}

@Test
class TomlCodecContractTests {
    // T012 -> S012, P011
    @TestCase
    func T012_manualAndGeneratedCodecsAggregateOrderedErrors(): Unit {
        let manual = TomlCodecs.array(TomlCodecs.int64)
        let badValues = TomlArray([TomlString("wrong"), TomlBoolean(true)])
        let manualFailure = manual.decode(badValues, TomlDecodeContext())
        @Expect(!manualFailure.isSuccess())
        @Expect(manualFailure.diagnostics().size, 2)
        @Expect(manualFailure.diagnostics()[0].path.getOrThrow().toString(), "$[0]")
        @Expect(manualFailure.diagnostics()[1].path.getOrThrow().toString(), "$[1]")

        let profile = TestCodecProfile("Ada", 37, None<String>)
        let encoded = encodeTomlWith(profile, TestCodecProfileToml).getOrThrow()
        @Expect(encoded, "user_name = \"Ada\"\nage = 37\n")
        let decoded = decodeTomlWith(encoded, TestCodecProfileToml).getOrThrow()
        @Expect(decoded.name, "Ada")
        @Expect(decoded.age, 37)
        @Expect(decoded.nick.isNone())

        let missingAndUnknown = decodeTomlWith("extra = 1\n", TestCodecProfileToml)
        @Expect(!missingAndUnknown.isSuccess())
        @Expect(missingAndUnknown.diagnostics().size, 3)
        @Expect(missingAndUnknown.diagnostics()[0].code, "missing_field")
        @Expect(missingAndUnknown.diagnostics()[1].code, "missing_field")
        @Expect(missingAndUnknown.diagnostics()[2].code, "unknown_field")

        let flattened = TestCodecEnvelope(TestCodecIdentity(7), true)
        @Expect(encodeTomlWith(flattened, TestCodecEnvelopeToml).getOrThrow(),
            "id = 7\nenabled = true\n")
        @Expect(decodeTomlWith("id = 9\nenabled = false\n", TestCodecEnvelopeToml)
            .getOrThrow().identity.id, 9)

        match (decodeTomlValue(TomlString("Fast"), TestCodecModeToml).getOrThrow()) {
            case TestCodecMode.Fast => ()
            case _ => @Fail("expected Fast enum value")
        }

        let timeZone = TimeZone("test", Duration.minute * 330)
        let dateTime = DateTime.of(year: 2026, month: 8, dayOfMonth: 30,
            hour: 12, minute: 34, second: 56, nanosecond: 123456789,
            timeZone: timeZone)
        let temporal = TomlCodecs.dateTime.encode(dateTime, TomlEncodeContext())
            .getOrThrow().asOffsetDateTime()
        @Expect(temporal.offsetMinutes, 330)
        @Expect(temporal.local.time.fraction, "123456789")
        let restored = temporal.toDateTime().getOrThrow()
        @Expect(restored.zoneOffset.toMinutes(), 330)
        @Expect(restored.nanosecond, 123456789)
        let tooPrecise = TomlOffsetDateTime(
            TomlLocalDateTime(TomlLocalDate(2026, 8, 30),
                TomlLocalTime(1, 2, second: 3, fraction: "1234567891")), 0)
        @Expect(!tooPrecise.toDateTime().isSuccess())

        @Expect(!TomlCodecs.int8.decode(TomlInteger(128), TomlDecodeContext()).isSuccess())
    }
}
