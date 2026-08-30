// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*
import std.math.numeric.BigInt

public enum TomlKind {
    String | Integer | Float | Boolean | OffsetDateTime | LocalDateTime |
    LocalDate | LocalTime | Array | Table
}

/// Base class for the mutable semantic TOML model.
public abstract class TomlValue <: ToString {
    public func kind(): TomlKind

    /// TOML semantic equality. Table insertion order and numeric lexemes are ignored.
    public func equivalentTo(other: TomlValue): Bool {
        tomlValuesEquivalent(this, other, false, 0)
    }

    /// Equality that additionally requires identical table insertion order.
    public func sameOrder(other: TomlValue): Bool {
        tomlValuesEquivalent(this, other, true, 0)
    }

    /// Returns a fully detached mutable tree. Shared children are copied per occurrence.
    public func deepCopy(): TomlValue {
        tomlDeepCopy(this, ArrayList<TomlValue>(), 0)
    }

    /// Captures an immutable snapshot. thaw() returns a copy-on-write mutable view.
    public func freeze(): FrozenTomlValue { FrozenTomlValue(this) }

    public func asString(): TomlString {
        match (this) { case value: TomlString => value; case _ => throw TomlException("expected TOML string") }
    }

    public func asInteger(): TomlInteger {
        match (this) { case value: TomlInteger => value; case _ => throw TomlException("expected TOML integer") }
    }

    public func asFloat(): TomlFloat {
        match (this) { case value: TomlFloat => value; case _ => throw TomlException("expected TOML float") }
    }

    public func asBoolean(): TomlBoolean {
        match (this) { case value: TomlBoolean => value; case _ => throw TomlException("expected TOML boolean") }
    }

    public func asOffsetDateTime(): TomlOffsetDateTime {
        match (this) { case value: TomlOffsetDateTime => value; case _ => throw TomlException("expected TOML offset date-time") }
    }

    public func asLocalDateTime(): TomlLocalDateTime {
        match (this) { case value: TomlLocalDateTime => value; case _ => throw TomlException("expected TOML local date-time") }
    }

    public func asLocalDate(): TomlLocalDate {
        match (this) { case value: TomlLocalDate => value; case _ => throw TomlException("expected TOML local date") }
    }

    public func asLocalTime(): TomlLocalTime {
        match (this) { case value: TomlLocalTime => value; case _ => throw TomlException("expected TOML local time") }
    }

    public func asArray(): TomlArray {
        match (this) { case value: TomlArray => value; case _ => throw TomlException("expected TOML array") }
    }

    public func asTable(): TomlTable {
        match (this) { case value: TomlTable => value; case _ => throw TomlException("expected TOML table") }
    }

    public func toString(): String
}

public class TomlString <: TomlValue {
    public let value: String

    public init(value: String) { this.value = value }
    public func kind(): TomlKind { TomlKind.String }
    public func toString(): String { value }
}

public class TomlInteger <: TomlValue {
    public let value: BigInt

    public init(value: BigInt) { this.value = value }
    public init(value: Int64) { this.value = BigInt(value) }
    public func kind(): TomlKind { TomlKind.Integer }
    public func toString(): String { value.toString() }
}

public class TomlFloat <: TomlValue {
    public let value: Float64

    public init(value: Float64) { this.value = value }
    public func kind(): TomlKind { TomlKind.Float }
    public func toString(): String {
        if (value.isNaN()) { return "nan" }
        if (value.isInf()) { return if (value < 0.0) { "-inf" } else { "inf" } }
        value.toString()
    }
}

public class TomlBoolean <: TomlValue {
    public let value: Bool

    public init(value: Bool) { this.value = value }
    public func kind(): TomlKind { TomlKind.Boolean }
    public func toString(): String { value.toString() }
}

/// Mutable, ordered TOML array. Mutations reject cycles.
public class TomlArray <: TomlValue {
    private let items: ArrayList<TomlValue>
    // Parser-only metadata; intentionally not part of the public semantic API.
    var parserArrayOfTables: Bool = false

    public init() { items = ArrayList<TomlValue>() }

    public init(values: Collection<TomlValue>) {
        items = ArrayList<TomlValue>()
        for (value in values) { add(value) }
    }

    public func kind(): TomlKind { TomlKind.Array }
    public prop size: Int64 { get() { items.size } }
    public prop isArrayOfTables: Bool { get() { parserArrayOfTables } }
    public func values(): ArrayList<TomlValue> { items.clone() }
    public func get(index: Int64): Option<TomlValue> { items.get(index) }

    public operator func [](index: Int64): TomlValue {
        get(index).getOrThrow({ => TomlException("array index ${index} is out of bounds") })
    }

    public operator func [](index: Int64, value!: TomlValue): Unit {
        let _ = set(index, value)
    }

    public func add(value: TomlValue): TomlArray {
        tomlEnsureCanAttach(this, value)
        items.add(value)
        this
    }

    public func insert(index: Int64, value: TomlValue): TomlArray {
        if (index < 0 || index > items.size) {
            throw TomlException("array index ${index} is out of bounds")
        }
        tomlEnsureCanAttach(this, value)
        items.add(value, at: index)
        this
    }

    public func set(index: Int64, value: TomlValue): TomlArray {
        if (index < 0 || index >= items.size) {
            throw TomlException("array index ${index} is out of bounds")
        }
        tomlEnsureCanAttach(this, value)
        items[index] = value
        this
    }

    public func removeAt(index: Int64): TomlValue {
        if (index < 0 || index >= items.size) {
            throw TomlException("array index ${index} is out of bounds")
        }
        items.remove(at: index)
    }

    /// Marks this homogeneous array for `[[array-of-tables]]` encoding.
    public func asArrayOfTables(): TomlArray {
        for (item in items) {
            match (item) {
                case _: TomlTable => ()
                case _ => throw TomlException("an array of tables may contain only TomlTable values")
            }
        }
        parserArrayOfTables = true
        this
    }

    public func toString(): String {
        let out = StringBuilder("[")
        for (index in 0..items.size) {
            if (index > 0) { out.append(", ") }
            out.append(tomlValueDebugText(items[index]))
        }
        out.append("]")
        out.toString()
    }
}

/// Mutable TOML table with deterministic insertion order.
public class TomlTable <: TomlValue {
    private let order: ArrayList<String>
    private let fields: HashMap<String, TomlValue>
    // 0=programmatic/root, 1=implicit header parent, 2=explicit header,
    // 3=dotted-key table, 4=sealed inline table, 5=array-of-tables element.
    var parserDefinitionState: Int64 = 0
    public let isInline: Bool

    public init(inline!: Bool = false) {
        order = ArrayList<String>()
        fields = HashMap<String, TomlValue>()
        isInline = inline
    }

    public func kind(): TomlKind { TomlKind.Table }
    public prop size: Int64 { get() { order.size } }
    public func contains(key: String): Bool { fields.contains(key) }
    public func get(key: String): Option<TomlValue> { fields.get(key) }
    public func keys(): ArrayList<String> { order.clone() }

    public operator func [](key: String): TomlValue {
        get(key).getOrThrow({ => TomlException("missing TOML key '${key}'") })
    }

    public operator func [](key: String, value!: TomlValue): Unit {
        let _ = put(key, value)
    }

    public func put(key: String, value: TomlValue): TomlTable {
        tomlEnsureCanAttach(this, value)
        if (!fields.contains(key)) { order.add(key) }
        let _ = fields.add(key, value)
        this
    }

    public func putIfAbsent(key: String, value: TomlValue): Bool {
        if (fields.contains(key)) { return false }
        let _ = put(key, value)
        true
    }

    public func remove(key: String): Option<TomlValue> {
        let removed = fields.remove(key)
        if (let Some(_) <- removed) {
            var found: Int64 = -1
            for (index in 0..order.size) {
                if (order[index] == key) { found = index; break }
            }
            if (found >= 0) { order.remove(at: found) }
        }
        removed
    }

    /// Moves key before `before`; None moves it to the end.
    public func reorder(key: String, before: Option<String>): Bool {
        if (!fields.contains(key)) { return false }
        var from: Int64 = -1
        for (index in 0..order.size) {
            if (order[index] == key) { from = index; break }
        }
        if (from < 0) { return false }
        order.remove(at: from)
        match (before) {
            case Some(target) =>
                var to: Int64 = -1
                for (index in 0..order.size) {
                    if (order[index] == target) { to = index; break }
                }
                if (to < 0) {
                    order.add(key)
                    return false
                }
                order.add(key, at: to)
            case None => order.add(key)
        }
        true
    }

    public func toString(): String {
        let out = StringBuilder("{")
        for (index in 0..order.size) {
            if (index > 0) { out.append(", ") }
            let key = order[index]
            out.append(key)
            out.append(" = ")
            out.append(tomlValueDebugText(fields[key]))
        }
        out.append("}")
        out.toString()
    }
}

/// Immutable semantic snapshot. No mutable node is exposed by this type.
public class FrozenTomlValue <: ToString {
    private let snapshot: TomlValue

    init(value: TomlValue) {
        snapshot = tomlDeepCopy(value, ArrayList<TomlValue>(), 0)
    }

    public func kind(): TomlKind { snapshot.kind() }
    public func equivalentTo(other: FrozenTomlValue): Bool { snapshot.equivalentTo(other.snapshot) }
    public func sameOrder(other: FrozenTomlValue): Bool { snapshot.sameOrder(other.snapshot) }

    /// Materializes mutable nodes only for this returned view.
    public func thaw(): TomlValue { tomlDeepCopy(snapshot, ArrayList<TomlValue>(), 0) }

    public func toString(): String { snapshot.toString() }
}

private func tomlValueDebugText(value: TomlValue): String {
    match (value) {
        case stringValue: TomlString =>
            let out = StringBuilder("\"")
            for (rune in stringValue.value.runes()) {
                if (rune == r'\\') { out.append("\\\\") }
                else if (rune == r'\"') { out.append("\\\"") }
                else if (rune == r'\n') { out.append("\\n") }
                else if (rune == r'\r') { out.append("\\r") }
                else if (rune == r'\t') { out.append("\\t") }
                else { out.append(rune) }
            }
            out.append("\"")
            out.toString()
        case _ => value.toString()
    }
}

private func tomlEnsureCanAttach(parent: TomlValue, child: TomlValue): Unit {
    if (tomlContainsReference(child, parent, ArrayList<TomlValue>(), 0)) {
        throw TomlException("cyclic TOML value graph is not supported",
            diagnostics: [TomlDiagnostic("cyclic_reference", TomlSeverity.Error,
                "attaching this value would create a cycle")])
    }
}

private func tomlContainsReference(
    value: TomlValue,
    target: TomlValue,
    ancestors: ArrayList<TomlValue>,
    depth: Int64
): Bool {
    if (refEq(value, target)) { return true }
    if (depth > 256) {
        throw TomlException("TOML value depth exceeds 256",
            diagnostics: [TomlDiagnostic("resource_limit", TomlSeverity.Error,
                "semantic graph depth exceeds 256")])
    }
    for (ancestor in ancestors) {
        if (refEq(value, ancestor)) {
            throw TomlException("cyclic TOML value graph is not supported",
                diagnostics: [TomlDiagnostic("cyclic_reference", TomlSeverity.Error,
                    "the supplied value already contains a cycle")])
        }
    }
    match (value) {
        case arrayValue: TomlArray =>
            ancestors.add(value)
            try {
                for (item in arrayValue.values()) {
                    if (tomlContainsReference(item, target, ancestors, depth + 1)) { return true }
                }
            } finally { ancestors.remove(at: ancestors.size - 1) }
            false
        case tableValue: TomlTable =>
            ancestors.add(value)
            try {
                for (key in tableValue.keys()) {
                    if (tomlContainsReference(tableValue[key], target, ancestors, depth + 1)) { return true }
                }
            } finally { ancestors.remove(at: ancestors.size - 1) }
            false
        case _ => false
    }
}

private func tomlValuesEquivalent(left: TomlValue, right: TomlValue, ordered: Bool, depth: Int64): Bool {
    if (depth > 256) {
        throw TomlException("TOML value comparison depth exceeds 256",
            diagnostics: [TomlDiagnostic("resource_limit", TomlSeverity.Error,
                "semantic comparison depth exceeds 256")])
    }
    match ((left, right)) {
        case (a: TomlString, b: TomlString) => a.value == b.value
        case (a: TomlInteger, b: TomlInteger) => a.value == b.value
        case (a: TomlFloat, b: TomlFloat) =>
            (a.value.isNaN() && b.value.isNaN()) || a.value == b.value
        case (a: TomlBoolean, b: TomlBoolean) => a.value == b.value
        case (a: TomlOffsetDateTime, b: TomlOffsetDateTime) => a == b
        case (a: TomlLocalDateTime, b: TomlLocalDateTime) => a == b
        case (a: TomlLocalDate, b: TomlLocalDate) => a == b
        case (a: TomlLocalTime, b: TomlLocalTime) => a == b
        case (a: TomlArray, b: TomlArray) =>
            if (a.size != b.size) { return false }
            for (index in 0..a.size) {
                if (!tomlValuesEquivalent(a[index], b[index], ordered, depth + 1)) { return false }
            }
            true
        case (a: TomlTable, b: TomlTable) =>
            if (a.size != b.size) { return false }
            let aKeys = a.keys()
            let bKeys = b.keys()
            if (ordered) {
                for (index in 0..aKeys.size) {
                    if (aKeys[index] != bKeys[index]) { return false }
                }
            }
            for (key in aKeys) {
                match ((a.get(key), b.get(key))) {
                    case (Some(av), Some(bv)) =>
                        if (!tomlValuesEquivalent(av, bv, ordered, depth + 1)) { return false }
                    case _ => return false
                }
            }
            true
        case _ => false
    }
}

private func tomlDeepCopy(value: TomlValue, ancestors: ArrayList<TomlValue>, depth: Int64): TomlValue {
    if (depth > 256) {
        throw TomlException("TOML value copy depth exceeds 256",
            diagnostics: [TomlDiagnostic("resource_limit", TomlSeverity.Error,
                "semantic copy depth exceeds 256")])
    }
    for (ancestor in ancestors) {
        if (refEq(value, ancestor)) {
            throw TomlException("cyclic TOML value graph is not supported",
                diagnostics: [TomlDiagnostic("cyclic_reference", TomlSeverity.Error,
                    "cannot copy a cyclic TOML value graph")])
        }
    }
    match (value) {
        case v: TomlString => TomlString(v.value)
        case v: TomlInteger => TomlInteger(v.value)
        case v: TomlFloat => TomlFloat(v.value)
        case v: TomlBoolean => TomlBoolean(v.value)
        case v: TomlOffsetDateTime => v.copyValue()
        case v: TomlLocalDateTime => v.copyValue()
        case v: TomlLocalDate => v.copyValue()
        case v: TomlLocalTime => v.copyValue()
        case v: TomlArray =>
            ancestors.add(value)
            let copy = TomlArray()
            try {
                for (item in v.values()) { copy.add(tomlDeepCopy(item, ancestors, depth + 1)) }
            } finally { ancestors.remove(at: ancestors.size - 1) }
            copy
        case v: TomlTable =>
            ancestors.add(value)
            let copy = TomlTable(inline: v.isInline)
            try {
                for (key in v.keys()) { copy.put(key, tomlDeepCopy(v[key], ancestors, depth + 1)) }
            } finally { ancestors.remove(at: ancestors.size - 1) }
            copy
        case _ => throw TomlException("unsupported TomlValue implementation")
    }
}
