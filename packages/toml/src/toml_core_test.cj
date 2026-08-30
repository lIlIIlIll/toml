// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*
import std.math.numeric.BigInt
import std.unittest.*
import std.unittest.testmacro.*

private func testHasDiagnostic(diagnostics: Collection<TomlDiagnostic>, code: String): Bool {
    for (diagnostic in diagnostics) {
        if (diagnostic.code == code) { return true }
    }
    false
}

@Test
class TomlCoreContractTests {
    // T001 -> S001, P001
    @TestCase
    func T001_parseRepresentativeDocument(): Unit {
        let text = """
        title = "TOML Example"
        owner.name = "Tom"
        owner.dob = 1979-05-27T07:32:00Z

        [database]
        enabled = true
        ports = [8000, 8001, 8002]

        [[products]]
        name = "Hammer"

        [[products]]
        name = "Nail"
        """
        let root = parseToml(text).getOrThrow()
        @Expect(root["title"].asString().value, "TOML Example")
        @Expect(root["owner"].asTable()["name"].asString().value, "Tom")
        @Expect(root["owner"].asTable()["dob"].asOffsetDateTime().offsetMinutes, 0)
        let database = root["database"].asTable()
        @Expect(database["enabled"].asBoolean().value)
        @Expect(database["ports"].asArray().size, 3)
        let products = root["products"].asArray()
        @Expect(products.isArrayOfTables)
        @Expect(products.size, 2)
        @Expect(products[1].asTable()["name"].asString().value, "Nail")
        @Expect(root.keys().toArray(), ["title", "owner", "database", "products"])
    }

    // T002 -> S002, P004
    @TestCase
    func T002_splitVersionSpecificSyntax(): Unit {
        let eleven = parseToml("escape = \"\\e\"\ntime = 07:32\n",
            options: TomlParseOptions.strict11)
        @Expect(eleven.isSuccess())
        @Expect(eleven.getOrThrow()["escape"].asString().value, "\u{1B}")
        @Expect(eleven.getOrThrow()["time"].asLocalTime().second, 0)

        let ten = parseToml("escape = \"\\e\"\ntime = 07:32\n",
            options: TomlParseOptions.strict10)
        @Expect(!ten.isSuccess())
        @Expect(testHasDiagnostic(ten.diagnostics(), "escape_requires_toml_1_1"))
    }

    // T003 -> S003/S005, P003/P006
    @TestCase
    func T003_reportSyntaxAndDuplicateErrors(): Unit {
        let malformed = parseToml("first = [1 2]\nsecond = 3\n")
        @Expect(!malformed.isSuccess())
        @Expect(testHasDiagnostic(malformed.diagnostics(), "missing_array_comma"))

        let duplicate = parseToml("name = \"first\"\nname = \"second\"\n")
        @Expect(!duplicate.isSuccess())
        @Expect(testHasDiagnostic(duplicate.diagnostics(), "duplicate_key"))
    }

    // T004 -> S004, P002
    @TestCase
    func T004_applyUtf8Policies(): Unit {
        let bytes: Array<Byte> = [b'v', b'a', b'l', b'u', b'e', b' ', b'=', b' ', b'\"', 0xFF, b'\"', b'\n']
        let rejected = parseToml(bytes)
        @Expect(!rejected.isSuccess())
        @Expect(testHasDiagnostic(rejected.diagnostics(), "invalid_utf8"))

        let replaced = parseToml(bytes,
            options: TomlParseOptions(utf8Policy: TomlUtf8Policy.ReplaceInvalid))
        @Expect(replaced.isSuccess())
        @Expect(testHasDiagnostic(replaced.diagnostics(), "invalid_utf8_replaced"))
        @Expect(replaced.getOrThrow()["value"].asString().value, "\u{FFFD}")
    }

    // T005 -> S006/S011, P001/P005
    @TestCase
    func T005_enforceIntegerAndInputLimits(): Unit {
        let portable = parseToml("n = 9223372036854775808\n")
        @Expect(!portable.isSuccess())
        @Expect(testHasDiagnostic(portable.diagnostics(), "integer_out_of_range"))

        let arbitrary = parseToml("n = 9223372036854775808\n",
            options: TomlParseOptions(integerMode: TomlIntegerMode.ArbitraryPrecision))
        @Expect(arbitrary.isSuccess())
        @Expect(arbitrary.getOrThrow()["n"].asInteger().value,
            BigInt.parse("9223372036854775808"))

        let limited = parseToml("answer = 42\n",
            options: TomlParseOptions(limits: TomlLimits(maxInputBytes: 5)))
        @Expect(!limited.isSuccess())
        @Expect(testHasDiagnostic(limited.diagnostics(), "input_too_large"))
    }

    // T006 -> S007, P007
    @TestCase
    func T006_encodeDeterministicallyAndRoundTrip(): Unit {
        let root = TomlTable()
        root.put("title", TomlString("demo"))
        let database = TomlTable()
        database.put("enabled", TomlBoolean(true))
        root.put("database", database)
        let products = TomlArray()
        products.add(TomlTable().put("name", TomlString("Hammer")))
        products.add(TomlTable().put("name", TomlString("Nail")))
        products.asArrayOfTables()
        root.put("products", products)

        let encoded = encodeToml(root).getOrThrow()
        @Expect(encoded,
            "title = \"demo\"\n\n[database]\nenabled = true\n\n[[products]]\nname = \"Hammer\"\n\n[[products]]\nname = \"Nail\"\n")
        @Expect(parseToml(encoded).getOrThrow().equivalentTo(root))
    }

    // T007 -> S008/S012, P009
    @TestCase
    func T007_equalityAndFrozenSnapshots(): Unit {
        let first = TomlTable().put("a", TomlFloat(Float64.NaN)).put("b", TomlInteger(0))
        let second = TomlTable().put("b", TomlInteger(0)).put("a", TomlFloat(Float64.NaN))
        @Expect(first.equivalentTo(second))
        @Expect(!first.sameOrder(second))

        let frozen = first.freeze()
        first.put("later", TomlBoolean(true))
        let thawed = frozen.thaw().asTable()
        @Expect(!thawed.contains("later"))
        thawed.put("copy", TomlString("independent"))
        @Expect(!frozen.thaw().asTable().contains("copy"))
    }

    // T008 -> S009, P008
    @TestCase
    func T008_rejectCyclesAndNonportableEncoding(): Unit {
        let array = TomlArray()
        let cycleError = @AssertThrows[TomlException](array.add(array))
        @Expect(testHasDiagnostic(cycleError.diagnostics, "cyclic_reference"))

        let root = TomlTable().put("n", TomlInteger(BigInt.parse("9223372036854775808")))
        let encoded = encodeToml(root)
        @Expect(!encoded.isSuccess())
        @Expect(testHasDiagnostic(encoded.diagnostics(), "integer_out_of_range"))
    }

    // T010 -> S013, P010
    @TestCase
    func T010_preserveBytesRevisionAndReusedNodeIds(): Unit {
        let original = parseTomlDocument("a = 1\nb = 2\n").getOrThrow()
        let originalNodes = original.nodes()
        @Expect(original.revision, 0)
        @Expect(original.sourceBytes(), tomlCloneStringBytes("a = 1\nb = 2\n"))

        let first = originalNodes[0]
        let second = originalNodes[2]
        @Expect(first.kind, TomlSyntaxKind.KeyValue)
        @Expect(second.kind, TomlSyntaxKind.KeyValue)
        let firstHandle = original.handle(first)
        let secondHandle = original.handle(second)

        let edited = original.beginEdit().replace(TomlSpan(10, 11), "20").commit().getOrThrow()
        @Expect(edited.revision, 1)
        @Expect(edited.sourceBytes(), tomlCloneStringBytes("a = 1\nb = 20\n"))
        @Expect(original.sourceBytes(), tomlCloneStringBytes("a = 1\nb = 2\n"))

        let relocatedFirst = edited.relocate(firstHandle)
        @Expect(relocatedFirst.isSome())
        @Expect(edited.resolve(relocatedFirst.getOrThrow()).getOrThrow().id, first.id)
        @Expect(edited.relocate(secondHandle).isNone())
        @Expect(edited.resolve(firstHandle).isNone())
        @Expect(edited.semantic().getOrThrow()["b"].asInteger().value, BigInt(20))
    }

    // T011 -> S014, P010
    @TestCase
    func T011_rejectOverlappingAndStaleEditsAtomically(): Unit {
        let original = parseTomlDocument("answer = 42\n").getOrThrow()
        let overlap = TomlEditBatch(original.revision)
            .replace(TomlSpan(0, 2), "x")
            .replace(TomlSpan(1, 3), "y")
        let rejected = original.apply(overlap)
        @Expect(!rejected.isSuccess())
        @Expect(testHasDiagnostic(rejected.diagnostics(), "overlapping_edits"))
        @Expect(original.text(), "answer = 42\n")

        let next = original.beginEdit().insert(original.byteLength, "# retained\n").commit().getOrThrow()
        let stale = next.apply(TomlEditBatch(original.revision).insert(0, "# stale\n"))
        @Expect(!stale.isSuccess())
        @Expect(testHasDiagnostic(stale.diagnostics(), "stale_revision"))
        @Expect(next.text(), "answer = 42\n# retained\n")

        let recovered = parseTomlDocument("bad = [1 2]\ngood = 3\n")
        @Expect(recovered.hasDocument)
        @Expect(recovered.hasErrors)
        @Expect(!recovered.getOrThrow().semantic().isSuccess())

        let invalid: Array<Byte> = [b'a', b' ', b'=', b' ', b'\"', 0xFF, b'\"']
        @Expect(parseTomlDocument(invalid).isFatal)
    }
}
