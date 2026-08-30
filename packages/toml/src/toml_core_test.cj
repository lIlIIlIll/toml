// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*
import std.io.*
import std.math.numeric.BigInt
import std.unittest.*
import std.unittest.testmacro.*

private func testHasDiagnostic(diagnostics: Collection<TomlDiagnostic>, code: String): Bool {
    for (diagnostic in diagnostics) {
        if (diagnostic.code == code) { return true }
    }
    false
}

private class TomlTestLcg {
    private var state: Int64

    init(seed: Int64) { state = seed }

    func next(): Int64 {
        state = (state * 48271) % 2147483647
        state
    }
}

private class TomlTestInputStream <: InputStream {
    private let source: Array<Byte>
    private let chunkSize: Int64
    private let fail: Bool
    private var offset: Int64 = 0
    var reads: Int64 = 0

    init(source: String, chunkSize!: Int64 = 3, fail!: Bool = false) {
        this.source = tomlCloneStringBytes(source)
        this.chunkSize = chunkSize
        this.fail = fail
    }

    public func read(buffer: Array<Byte>): Int64 {
        reads++
        if (fail) { throw Exception("synthetic read failure") }
        if (offset >= source.size) { return 0 }
        let remaining = source.size - offset
        let count = if (remaining < chunkSize) { remaining } else { chunkSize }
        source.copyTo(buffer, offset, 0, count)
        offset += count
        count
    }
}

private class TomlTestOutputStream <: OutputStream {
    private let fail: Bool
    let bytes = ArrayList<Byte>()
    var flushes: Int64 = 0

    init(fail!: Bool = false) { this.fail = fail }

    public func write(buffer: Array<Byte>): Unit {
        if (fail) { throw Exception("synthetic write failure") }
        bytes.add(all: buffer)
    }

    public func flush(): Unit { flushes++ }
}

private func testGeneratedTable(random: TomlTestLcg, caseIndex: Int64): TomlTable {
    let root = TomlTable()
    root.put("case_${caseIndex}", TomlInteger(random.next() % 1_000_000))
    root.put("enabled", TomlBoolean(random.next() % 2 == 0))
    root.put("label", TomlString("case-${caseIndex}-${random.next()}-\u{4ED3}\u{9889}"))

    let values = TomlArray()
    let valueCount = random.next() % 6
    for (_ in 0..valueCount) {
        values.add(TomlInteger(random.next() % 100_000))
    }
    root.put("values", values)

    let nested = TomlTable()
    nested.put("quoted", TomlString("line\\nquote\\\"slash\\\\-${random.next()}"))
    nested.put("ratio", TomlFloat(Float64(random.next() % 10_000) / 100.0))
    root.put("nested", nested)
    root
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

    // T003 -> S003, P003/P006
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

    // T005 -> S005, P001/P005
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

    // T006 -> S006, P007
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

    // T007 -> S007, P009
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

    // T008 -> S008, P008
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

    // T010 -> S010, P010
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

    // T011 -> S011, P010
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

    // T013 -> S013, P010
    @TestCase
    func T013_applyStructuredEditsWithoutRewritingUnrelatedBytes(): Unit {
        let original = parseTomlDocument(
            "title = \"old\"  # keep\n[db]\nport = 5432\n").getOrThrow()
        let title = TomlPath().withKey("title")
        let port = TomlPath().withKey("db").withKey("port")
        let host = TomlPath().withKey("db").withKey("host")

        let session = original.beginEdit()
        @Expect(session.replaceValue(title, TomlString("new")).isSuccess())
        @Expect(session.renameKey(port, "server_port").isSuccess())
        @Expect(session.insertValue(host, TomlString("localhost")).isSuccess())
        let edited = session.commit().getOrThrow()
        @Expect(edited.text(),
            "title = \"new\"  # keep\n[db]\nserver_port = 5432\nhost = \"localhost\"\n")
        @Expect(original.text(),
            "title = \"old\"  # keep\n[db]\nport = 5432\n")

        let moved = edited.beginEdit()
        @Expect(moved.moveBefore(host,
            TomlPath().withKey("db").withKey("server_port")).isSuccess())
        let reordered = moved.commit().getOrThrow()
        @Expect(reordered.text(),
            "title = \"new\"  # keep\n[db]\nhost = \"localhost\"\nserver_port = 5432\n")

        let removed = reordered.beginEdit()
        @Expect(removed.removeValue(title).isSuccess())
        @Expect(removed.commit().getOrThrow().text().contains("# keep\n"))

        let created = parseTomlDocument("").getOrThrow().beginEdit()
        @Expect(created.insertValue(
            TomlPath().withKey("server").withKey("tls").withKey("enabled"),
            TomlBoolean(true), createParents: true).isSuccess())
        @Expect(created.commit().getOrThrow().text(),
            "[server.tls]\nenabled = true\n")
    }

    // T014 -> S014, P010/P012
    @TestCase
    func T014_formatAndLintAsPureAtomicEdits(): Unit {
        let source = "answer=  42   \r\n# keep   \r\n"
        let original = parseTomlDocument(source).getOrThrow()
        let statement = original.nodes()[0]
        @Expect(statement.child(TomlSyntaxKind.Key).getOrThrow().span, TomlSpan(0, 6))
        @Expect(statement.child(TomlSyntaxKind.Value).getOrThrow().span, TomlSpan(9, 11))
        let style = TomlStyle(newline: TomlNewline.CrLf)
        let formatter = TomlFormatter(style: style)
        let preview = formatter.preview(original).getOrThrow()
        @Expect(preview.size, 3)
        @Expect(original.text(), source)

        let formatted = formatter.apply(original).getOrThrow()
        @Expect(formatted.text(), "answer = 42\r\n# keep\r\n")
        @Expect(formatted.revision, 1)
        @Expect(original.revision, 0)

        let lint = TomlLinter(style: style).lint(original)
        @Expect(lint.hasProblems)
        @Expect(!lint.hasErrors)
        @Expect(lint.hasFixes)
        @Expect(lint.fixes().size, 3)
        let fixed = TomlLinter(style: style).applyFixes(original).getOrThrow()
        @Expect(fixed.text(), formatted.text())

        let invalid = parseTomlDocument("bad = [1 2]\n").getOrThrow()
        let invalidLint = lintTomlDocument(invalid)
        @Expect(invalidLint.hasErrors)
        @Expect(!fixTomlDocument(invalid).isSuccess())
    }

    // T019 -> S019, P001/P007/P014
    @TestCase
    func T019_deterministicSemanticRoundTripProperty(): Unit {
        let random = TomlTestLcg(20260830)
        for (caseIndex in 0..128) {
            let value = testGeneratedTable(random, caseIndex)
            let encoded = encodeToml(value)
            @Expect(encoded.isSuccess())
            let reparsed = parseToml(encoded.getOrThrow())
            @Expect(reparsed.isSuccess())
            @Expect(reparsed.getOrThrow().equivalentTo(value))
        }
    }

    // T020 -> S020, P002/P005/P014
    @TestCase
    func T020_mutationFuzzSmokeAndResourceBudgets(): Unit {
        let fixture = tomlCloneStringBytes(
            "title = \"stable\"\n[server]\nports = [8000, 8001]\nenabled = true\n")
        let replacements: Array<Byte> = [0x00, b'\"', b'[', b']', b'#', b'\n', 0xFF]
        for (offset in 0..fixture.size) {
            for (replacement in replacements) {
                let mutated = fixture.clone()
                mutated[offset] = replacement
                let result = parseTomlDocument(mutated)
                @Expect(result.hasDocument || result.isFatal)
                if (result.hasDocument) {
                    @Expect(result.getOrThrow().sourceBytes(), mutated)
                }
            }
        }

        let depthLimited = parseTomlDocument("value = [[[[0]]]]\n",
            options: TomlParseOptions(limits: TomlLimits(maxDepth: 2)))
        @Expect(depthLimited.isFatal)
        @Expect(testHasDiagnostic(depthLimited.diagnostics(), "depth_limit"))

        let tokenLimited = parseTomlDocument("a = 1\nb = 2\n",
            options: TomlParseOptions(limits: TomlLimits(maxTokens: 1)))
        @Expect(tokenLimited.isFatal)
        @Expect(testHasDiagnostic(tokenLimited.diagnostics(), "token_limit"))

        let nodeLimited = parseTomlDocument("a = 1\n",
            options: TomlParseOptions(limits: TomlLimits(maxNodes: 1)))
        @Expect(nodeLimited.isFatal)
        @Expect(testHasDiagnostic(nodeLimited.diagnostics(), "node_limit"))

        let keyLimited = parseTomlDocument("a.b.c = 1\n",
            options: TomlParseOptions(limits: TomlLimits(maxKeySegments: 2)))
        @Expect(keyLimited.isFatal)
        @Expect(testHasDiagnostic(keyLimited.diagnostics(), "key_segment_limit"))
    }

    // T022 -> S022, P001/P003/P007
    @TestCase
    func T022_conformanceRegressionsForNumbersCommentsAndDottedKeys(): Unit {
        let based = parseToml("hex = 0xDEAD_BEEF\noct = 0o755\nbin = 0b11010110\n")
        @Expect(based.isSuccess())
        @Expect(based.getOrThrow()["hex"].asInteger().value, BigInt(0xDEADBEEF))
        @Expect(based.getOrThrow()["oct"].asInteger().value, BigInt(493))
        @Expect(based.getOrThrow()["bin"].asInteger().value, BigInt(214))

        for (source in ["n = -0xff\n", "n = +0o755\n", "n = -0b1\n"]) {
            let rejected = parseToml(source)
            @Expect(!rejected.isSuccess())
            @Expect(testHasDiagnostic(rejected.diagnostics(), "signed_base_integer"))
        }

        let precise = parseToml("value = 3.141592653589793\n")
            .getOrThrow()["value"].asFloat()
        @Expect(precise.toString(), "3.1415926535897931")
        let tiny = parseToml("value = 6.626e-34\n").getOrThrow()
        @Expect(parseToml(encodeToml(tiny).getOrThrow()).getOrThrow().equivalentTo(tiny))

        let controlComment = parseToml("value = 1 # \u{007F}\n")
        @Expect(!controlComment.isSuccess())
        @Expect(testHasDiagnostic(controlComment.diagnostics(), "control_character"))

        let inlineOverwrite = parseToml(
            "tab = { inner = { dog = \"best\" }, inner.cat = \"worst\" }\n")
        @Expect(!inlineOverwrite.isSuccess())
        @Expect(testHasDiagnostic(inlineOverwrite.diagnostics(), "dotted_key_redefines_table"))

        let headerOverwrite = parseToml("[a.b.c]\nz = 9\n[a]\nb.c.t = \"invalid\"\n")
        @Expect(!headerOverwrite.isSuccess())
        @Expect(testHasDiagnostic(headerOverwrite.diagnostics(), "dotted_key_redefines_table"))

        let dottedSiblings = parseToml("value = { a.b = 1, a.c = 2 }\n")
        @Expect(dottedSiblings.isSuccess())
    }

    // T026 -> S009, P001/P008/P015
    @TestCase
    func T026_streamOwnershipAndFailures(): Unit {
        let input = TomlTestInputStream("answer = 42\n")
        let parsed = TomlParser().parse(input)
        @Expect(parsed.getOrThrow()["answer"].asInteger().value, BigInt(42))
        @Expect(input.reads > 1)

        @Expect(parseToml(TomlTestInputStream("name = \"function\"\n")).isSuccess())
        @Expect(Toml.parse(TomlTestInputStream("name = \"static\"\n")).isSuccess())
        @Expect(TomlParser().parseOrThrow(
            TomlTestInputStream("name = \"throwing\"\n"))["name"].asString().value,
            "throwing")

        let readFailure = TomlParser().parse(TomlTestInputStream("", fail: true))
        @Expect(!readFailure.isSuccess())
        @Expect(testHasDiagnostic(readFailure.diagnostics(), "stream_read_error"))

        let smallLimit = TomlParseOptions(limits: TomlLimits(maxInputBytes: 4))
        let oversized = TomlParser(options: smallLimit)
            .parse(TomlTestInputStream("answer = 42\n", chunkSize: 20))
        @Expect(!oversized.isSuccess())
        @Expect(testHasDiagnostic(oversized.diagnostics(), "input_too_large"))

        let document = parseTomlDocument(TomlTestInputStream("doc = true\n"))
        @Expect(document.getOrThrow().semantic().getOrThrow()["doc"].asBoolean().value)
        let documentReadFailure = parseTomlDocument(TomlTestInputStream("", fail: true))
        @Expect(documentReadFailure.isFatal)
        @Expect(testHasDiagnostic(documentReadFailure.diagnostics(), "stream_read_error"))
        let documentOversized = TomlDocumentParser(options: smallLimit)
            .parse(TomlTestInputStream("answer = 42\n", chunkSize: 20))
        @Expect(documentOversized.isFatal)
        @Expect(testHasDiagnostic(documentOversized.diagnostics(), "input_too_large"))

        let table = TomlTable().put("answer", TomlInteger(42))
        let output = TomlTestOutputStream()
        @Expect(TomlEncoder().encodeTo(table, output).isSuccess())
        @Expect(output.bytes.toArray(), tomlCloneStringBytes("answer = 42\n"))
        @Expect(output.flushes, 0)
        @Expect(TomlEncoder().encodeBytes(table).getOrThrow(),
            tomlCloneStringBytes("answer = 42\n"))
        @Expect(Toml.encode(table).getOrThrow(), "answer = 42\n")
        @Expect(formatTomlValue(TomlString("fragment")).getOrThrow(), "\"fragment\"")

        let writeFailure = TomlEncoder().encodeTo(table, TomlTestOutputStream(fail: true))
        @Expect(!writeFailure.isSuccess())
        @Expect(testHasDiagnostic(writeFailure.diagnostics(), "stream_write_error"))
    }
}
