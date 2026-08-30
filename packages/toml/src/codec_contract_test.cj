// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*
import std.math.numeric.BigInt
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

private class TestManualRecord {
    let value: Int64
    init(value: Int64) { this.value = value }
}

private class TestManualRecordCodec <: TomlCodec<TestManualRecord> {
    public func encode(value: TestManualRecord, context: TomlEncodeContext): TomlOutcome<TomlValue> {
        match (TomlCodecs.int64.encode(value.value, context.atKey("value"))) {
            case TomlOutcome<TomlValue>.Success(item, diagnostics) =>
                TomlOutcome<TomlValue>.Success(TomlTable().put("value", item), diagnostics)
            case TomlOutcome<TomlValue>.Failure(diagnostics) =>
                TomlOutcome<TomlValue>.Failure(diagnostics)
        }
    }

    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<TestManualRecord> {
        match (TomlGeneratedSupportV1.expectTable(value, context)) {
            case TomlOutcome<TomlTable>.Success(table, _) =>
                match (table.get("value")) {
                    case Some(item) =>
                        match (TomlCodecs.int64.decode(item, context.atKey("value"))) {
                            case TomlOutcome<Int64>.Success(decoded, diagnostics) =>
                                TomlOutcome<TestManualRecord>.Success(TestManualRecord(decoded), diagnostics)
                            case TomlOutcome<Int64>.Failure(diagnostics) =>
                                TomlOutcome<TestManualRecord>.Failure(diagnostics)
                        }
                    case None => TomlGeneratedSupportV1.missingField<TestManualRecord>("value", context)
                }
            case TomlOutcome<TomlTable>.Failure(diagnostics) =>
                TomlOutcome<TestManualRecord>.Failure(diagnostics)
        }
    }
}

private let TEST_MANUAL_RECORD_CODEC: TomlCodec<TestManualRecord> = TestManualRecordCodec()

private class TestManualRecordProvider <: TomlCodecProvider {
    let value: Int64
    init(value: Int64) { this.value = value }

    public static func tomlCodec(): TomlAnyCodec {
        eraseTomlCodec<TestManualRecordProvider>(TestManualRecordProviderCodec())
    }
}

private class TestManualRecordProviderCodec <: TomlCodec<TestManualRecordProvider> {
    public func encode(value: TestManualRecordProvider, context: TomlEncodeContext): TomlOutcome<TomlValue> {
        TestManualRecordCodec().encode(TestManualRecord(value.value), context)
    }

    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<TestManualRecordProvider> {
        match (TestManualRecordCodec().decode(value, context)) {
            case TomlOutcome<TestManualRecord>.Success(decoded, diagnostics) =>
                TomlOutcome<TestManualRecordProvider>.Success(
                    TestManualRecordProvider(decoded.value), diagnostics)
            case TomlOutcome<TestManualRecord>.Failure(diagnostics) =>
                TomlOutcome<TestManualRecordProvider>.Failure(diagnostics)
        }
    }
}

private class TestMismatchedProvider <: TomlCodecProvider {
    public static func tomlCodec(): TomlAnyCodec {
        eraseTomlCodec<String>(TomlCodecs.string)
    }
}

@Test
class TomlCodecCoverageContractTests {
    // T023 -> S023, P011
    @TestCase
    func T023_builtinScalarAndTemporalCodecs(): Unit {
        @Expect(TomlCodecs.string.decode(
            TomlCodecs.string.encode("text", TomlEncodeContext()).getOrThrow(),
            TomlDecodeContext()).getOrThrow(), "text")
        @Expect(!TomlCodecs.string.decode(TomlInteger(1), TomlDecodeContext()).isSuccess())
        @Expect(TomlCodecs.bool.decode(
            TomlCodecs.bool.encode(true, TomlEncodeContext()).getOrThrow(),
            TomlDecodeContext()).getOrThrow())
        @Expect(!TomlCodecs.bool.decode(TomlString("true"), TomlDecodeContext()).isSuccess())

        let huge = BigInt.parse("9223372036854775808")
        @Expect(TomlCodecs.bigInt.decode(
            TomlCodecs.bigInt.encode(huge, TomlEncodeContext()).getOrThrow(),
            TomlDecodeContext()).getOrThrow(), huge)
        @Expect(!TomlCodecs.int64.decode(TomlInteger(huge), TomlDecodeContext()).isSuccess())
        @Expect(!TomlCodecs.int64.decode(TomlString("1"), TomlDecodeContext()).isSuccess())
        @Expect(TomlCodecs.int32.decode(
            TomlCodecs.int32.encode(42, TomlEncodeContext()).getOrThrow(),
            TomlDecodeContext()).getOrThrow(), 42)
        @Expect(TomlCodecs.int16.decode(TomlInteger(32767), TomlDecodeContext()).isSuccess())
        @Expect(TomlCodecs.int8.decode(TomlInteger(127), TomlDecodeContext()).isSuccess())
        @Expect(!TomlCodecs.int8.decode(TomlInteger(128), TomlDecodeContext()).isSuccess())
        @Expect(TomlCodecs.uint64.decode(TomlInteger(9), TomlDecodeContext()).isSuccess())
        @Expect(TomlCodecs.uint32.decode(TomlInteger(9), TomlDecodeContext()).isSuccess())
        @Expect(TomlCodecs.uint16.decode(TomlInteger(9), TomlDecodeContext()).isSuccess())
        @Expect(TomlCodecs.uint8.decode(TomlInteger(9), TomlDecodeContext()).isSuccess())
        @Expect(!TomlCodecs.uint8.decode(TomlInteger(-1), TomlDecodeContext()).isSuccess())

        @Expect(TomlCodecs.float64.decode(
            TomlCodecs.float64.encode(1.25, TomlEncodeContext()).getOrThrow(),
            TomlDecodeContext()).getOrThrow(), 1.25)
        @Expect(!TomlCodecs.float64.decode(TomlInteger(1), TomlDecodeContext()).isSuccess())
        @Expect(TomlCodecs.float32.decode(
            TomlCodecs.float32.encode(1.5, TomlEncodeContext()).getOrThrow(),
            TomlDecodeContext()).getOrThrow(), 1.5)
        @Expect(!TomlCodecs.float32.decode(TomlString("1.5"), TomlDecodeContext()).isSuccess())

        let original = TomlTable().put("key", TomlString("value"))
        let copied = TomlCodecs.value.encode(original, TomlEncodeContext()).getOrThrow().asTable()
        copied.put("later", TomlBoolean(true))
        @Expect(!original.contains("later"))
        let decodedCopy = TomlCodecs.value.decode(original, TomlDecodeContext()).getOrThrow().asTable()
        decodedCopy.put("copy", TomlBoolean(true))
        @Expect(!original.contains("copy"))

        let date = TomlLocalDate(2024, 2, 29)
        let time = TomlLocalTime(23, 59, second: 58, fraction: "123")
        let local = TomlLocalDateTime(date, time)
        let offset = TomlOffsetDateTime(local, 330)
        @Expect(TomlCodecs.localDate.decode(
            TomlCodecs.localDate.encode(date, TomlEncodeContext()).getOrThrow(),
            TomlDecodeContext()).getOrThrow(), date)
        @Expect(TomlCodecs.localTime.decode(
            TomlCodecs.localTime.encode(time, TomlEncodeContext()).getOrThrow(),
            TomlDecodeContext()).getOrThrow(), time)
        @Expect(TomlCodecs.localDateTime.decode(
            TomlCodecs.localDateTime.encode(local, TomlEncodeContext()).getOrThrow(),
            TomlDecodeContext()).getOrThrow(), local)
        @Expect(TomlCodecs.offsetDateTime.decode(
            TomlCodecs.offsetDateTime.encode(offset, TomlEncodeContext()).getOrThrow(),
            TomlDecodeContext()).getOrThrow(), offset)
        @Expect(!TomlCodecs.localDate.decode(TomlString("2024-02-29"), TomlDecodeContext()).isSuccess())
        @Expect(!TomlCodecs.localTime.decode(TomlString("23:59:58"), TomlDecodeContext()).isSuccess())
        @Expect(!TomlCodecs.localDateTime.decode(TomlString("x"), TomlDecodeContext()).isSuccess())
        @Expect(!TomlCodecs.offsetDateTime.decode(TomlString("x"), TomlDecodeContext()).isSuccess())

        let dateTime = DateTime.of(year: 2026, month: 8, dayOfMonth: 30,
            hour: 12, minute: 34, second: 56, nanosecond: 123456789,
            timeZone: TimeZone("test", Duration.minute * 330))
        let encodedDateTime = TomlCodecs.dateTime.encode(dateTime, TomlEncodeContext())
        @Expect(encodedDateTime.isSuccess())
        let restored = TomlCodecs.dateTime.decode(encodedDateTime.getOrThrow(), TomlDecodeContext())
        @Expect(restored.isSuccess())
        @Expect(restored.getOrThrow().zoneOffset.toMinutes(), 330)
        @Expect(!TomlCodecs.dateTime.decode(TomlString("x"), TomlDecodeContext()).isSuccess())
    }

    // T024 -> S024, P011
    @TestCase
    func T024_collectionCodecsAggregateFailFastAndDepth(): Unit {
        let arrayCodec = TomlCodecs.array(TomlCodecs.int64)
        let encoded = arrayCodec.encode([1, 2, 3], TomlEncodeContext()).getOrThrow().asArray()
        @Expect(encoded.size, 3)
        @Expect(arrayCodec.decode(encoded, TomlDecodeContext()).getOrThrow(), [1, 2, 3])
        @Expect(!arrayCodec.decode(TomlString("x"), TomlDecodeContext()).isSuccess())

        let bad = TomlArray([TomlString("a"), TomlBoolean(false)])
        let aggregate = arrayCodec.decode(bad, TomlDecodeContext())
        @Expect(aggregate.diagnostics().size, 2)
        let failFast = arrayCodec.decode(bad, TomlDecodeContext(options:
            TomlCodecOptions(aggregateErrors: false)))
        @Expect(failFast.diagnostics().size, 1)
        let shallow = TomlCodecOptions(maxDepth: 1)
        @Expect(!arrayCodec.encode([1], TomlEncodeContext(options: shallow, depth: 1)).isSuccess())
        @Expect(!arrayCodec.decode(encoded,
            TomlDecodeContext(options: shallow, depth: 1)).isSuccess())

        let optionalArray = TomlCodecs.array(TomlCodecs.option(TomlCodecs.string))
        let options: Array<Option<String>> = [Some("ok"), None<String>]
        @Expect(!optionalArray.encode(options, TomlEncodeContext()).isSuccess())
        @Expect(!optionalArray.encode(options, TomlEncodeContext(options:
            TomlCodecOptions(aggregateErrors: false))).isSuccess())

        let listCodec = TomlCodecs.arrayList(TomlCodecs.string)
        let list = ArrayList<String>(["a", "b"])
        @Expect(listCodec.decode(listCodec.encode(list, TomlEncodeContext()).getOrThrow(),
            TomlDecodeContext()).getOrThrow().size, 2)
        @Expect(!listCodec.decode(TomlInteger(1), TomlDecodeContext()).isSuccess())

        let map = HashMap<String, Int64>()
        let _ = map.add("a", 1)
        let _ = map.add("b", 2)
        let mapCodec = TomlCodecs.stringMap(TomlCodecs.int64)
        let mapValue = mapCodec.encode(map, TomlEncodeContext()).getOrThrow()
        let decodedMap = mapCodec.decode(mapValue, TomlDecodeContext()).getOrThrow()
        @Expect(decodedMap["a"], 1)
        @Expect(decodedMap["b"], 2)
        @Expect(!mapCodec.decode(TomlArray(), TomlDecodeContext()).isSuccess())
        @Expect(!mapCodec.encode(map, TomlEncodeContext(options: shallow, depth: 1)).isSuccess())
        @Expect(!mapCodec.decode(mapValue,
            TomlDecodeContext(options: shallow, depth: 1)).isSuccess())

        let brokenMap = TomlTable(inline: true)
            .put("a", TomlString("bad")).put("b", TomlBoolean(false))
        @Expect(mapCodec.decode(brokenMap, TomlDecodeContext()).diagnostics().size, 2)
        @Expect(mapCodec.decode(brokenMap, TomlDecodeContext(options:
            TomlCodecOptions(aggregateErrors: false))).diagnostics().size, 1)

        let someCodec = TomlCodecs.option(TomlCodecs.string)
        @Expect(someCodec.decode(TomlString("yes"), TomlDecodeContext())
            .getOrThrow().getOrThrow(), "yes")
        @Expect(!someCodec.decode(TomlInteger(1), TomlDecodeContext()).isSuccess())
        @Expect(!someCodec.encode(None<String>, TomlEncodeContext()).isSuccess())
    }

    // T025 -> S025, P011
    @TestCase
    func T025_documentWrappersProvidersAndGeneratedSupport(): Unit {
        let record = TestManualRecord(7)
        @Expect(encodeTomlWith(record, TEST_MANUAL_RECORD_CODEC).getOrThrow(), "value = 7\n")
        @Expect(decodeTomlWith("value = 9\n", TEST_MANUAL_RECORD_CODEC)
            .getOrThrow().value, 9)
        @Expect(!decodeTomlWith("value = [\n", TEST_MANUAL_RECORD_CODEC).isSuccess())
        @Expect(!encodeTomlWith("scalar", TomlCodecs.string).isSuccess())
        @Expect(!encodeTomlWith<TomlValue>(
            TomlTable().put("n", TomlInteger(BigInt.parse("9223372036854775808"))),
            TomlCodecs.value).isSuccess())

        let provider = TestManualRecordProvider(11)
        @Expect(encodeToml(provider).getOrThrow(), "value = 11\n")
        @Expect(decodeToml<TestManualRecordProvider>("value = 12\n").getOrThrow().value, 12)
        @Expect(encodeTomlValue(provider).getOrThrow().asTable()["value"].asInteger().value,
            BigInt(11))
        @Expect(decodeTomlValue<TestManualRecordProvider>(
            TomlTable().put("value", TomlInteger(13))).getOrThrow().value, 13)

        @Expect(@AssertThrows[IllegalArgumentException](tomlCodecOf<TestMismatchedProvider>())
            .message.contains("different type"))

        @Expect(TomlGeneratedSupportV1.abiVersion, 1)
        @Expect(TomlGeneratedSupportV1.success(3).getOrThrow(), 3)
        @Expect(!TomlGeneratedSupportV1.failure<Int64>(
            "test", "failure", TomlPath()).isSuccess())
        @Expect(TomlGeneratedSupportV1.diagnostic(
            "test", "diagnostic", TomlPath()).code, "test")
        @Expect(!TomlGeneratedSupportV1.missingField<Int64>(
            "required", TomlDecodeContext()).isSuccess())
        @Expect(TomlGeneratedSupportV1.expectTable(TomlTable(), TomlDecodeContext()).isSuccess())
        @Expect(!TomlGeneratedSupportV1.expectTable(
            TomlString("x"), TomlDecodeContext()).isSuccess())

        let input = TomlTable().put("known", TomlInteger(1)).put("extra", TomlInteger(2))
        let known: Array<String> = ["known"]
        let unknown = TomlGeneratedSupportV1.unknownFields(input, known, TomlDecodeContext())
        @Expect(unknown.size, 1)
        @Expect(unknown[0].path.getOrThrow().toString(), "$.extra")
        @Expect(TomlGeneratedSupportV1.unknownFields(input, known,
            TomlDecodeContext(options: TomlCodecOptions(
                unknownFields: TomlUnknownFieldPolicy.Ignore))).isEmpty())
        @Expect(TomlGeneratedSupportV1.fieldName("userName", TomlFieldNaming.Exact), "userName")
        @Expect(TomlGeneratedSupportV1.fieldName("userName", TomlFieldNaming.SnakeCase), "user_name")
        @Expect(TomlGeneratedSupportV1.fieldName("URLValue", TomlFieldNaming.KebabCase), "u-r-l-value")

        @Expect(TomlEncodeContext().atKey("a").atIndex(2).path.toString(), "$.a[2]")
        @Expect(TomlDecodeContext().atKey("a").atIndex(2).path.toString(), "$.a[2]")
        @Expect(@AssertThrows[IllegalArgumentException](TomlCodecOptions(maxDepth: 0))
            .message.contains("positive"))
    }
}
