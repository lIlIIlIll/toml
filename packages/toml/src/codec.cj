// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*
import std.convert.Parsable
import std.math.numeric.BigInt
import std.time.DateTime

public enum TomlUnknownFieldPolicy {
    Reject | Ignore
}

public enum TomlFieldNaming {
    Exact | SnakeCase | KebabCase
}

/// Runtime policies shared by manual and generated codecs.
public class TomlCodecOptions {
    public let unknownFields: TomlUnknownFieldPolicy
    public let fieldNaming: TomlFieldNaming
    public let aggregateErrors: Bool
    public let maxDepth: Int64

    public init(
        unknownFields!: TomlUnknownFieldPolicy = TomlUnknownFieldPolicy.Reject,
        fieldNaming!: TomlFieldNaming = TomlFieldNaming.Exact,
        aggregateErrors!: Bool = true,
        maxDepth!: Int64 = 256
    ) {
        if (maxDepth <= 0) { throw IllegalArgumentException("codec maxDepth must be positive") }
        this.unknownFields = unknownFields
        this.fieldNaming = fieldNaming
        this.aggregateErrors = aggregateErrors
        this.maxDepth = maxDepth
    }

    public static let defaults = TomlCodecOptions()
}

/// Immutable per-operation context for encoders.
public class TomlEncodeContext {
    public let options: TomlCodecOptions
    public let path: TomlPath
    public let depth: Int64

    public init(
        options!: TomlCodecOptions = TomlCodecOptions.defaults,
        path!: TomlPath = TomlPath(),
        depth!: Int64 = 0
    ) {
        this.options = options
        this.path = path
        this.depth = depth
    }

    public func atKey(key: String): TomlEncodeContext {
        TomlEncodeContext(options: options, path: path.withKey(key), depth: depth + 1)
    }

    public func atIndex(index: Int64): TomlEncodeContext {
        TomlEncodeContext(options: options, path: path.withIndex(index), depth: depth + 1)
    }
}

/// Immutable per-operation context for decoders.
public class TomlDecodeContext {
    public let options: TomlCodecOptions
    public let path: TomlPath
    public let depth: Int64

    public init(
        options!: TomlCodecOptions = TomlCodecOptions.defaults,
        path!: TomlPath = TomlPath(),
        depth!: Int64 = 0
    ) {
        this.options = options
        this.path = path
        this.depth = depth
    }

    public func atKey(key: String): TomlDecodeContext {
        TomlDecodeContext(options: options, path: path.withKey(key), depth: depth + 1)
    }

    public func atIndex(index: Int64): TomlDecodeContext {
        TomlDecodeContext(options: options, path: path.withIndex(index), depth: depth + 1)
    }
}

public interface TomlEncode<T> {
    func encode(value: T, context: TomlEncodeContext): TomlOutcome<TomlValue>
}

public interface TomlDecode<T> {
    func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<T>
}

public interface TomlCodec<T> <: TomlEncode<T> & TomlDecode<T> {}

/// Optional richer contract for record-like codecs. It is the only protocol
/// used to implement flattening; generated code never inspects runtime fields.
public interface TomlObjectCodec<T> <: TomlCodec<T> {
    func fieldNames(options: TomlCodecOptions): ArrayList<String>
    func encodeFields(value: T, context: TomlEncodeContext): TomlOutcome<TomlTable>
    func decodeFields(
        table: TomlTable,
        context: TomlDecodeContext,
        checkUnknown: Bool
    ): TomlOutcome<T>
}

/// Type-erased bridge used only by explicit, statically declared providers.
public interface TomlAnyCodec {
    func encodeAny(value: Any, context: TomlEncodeContext): TomlOutcome<TomlValue>
    func decodeAny(value: TomlValue, context: TomlDecodeContext): TomlOutcome<Any>
}

/// A type can opt into its generated or manually supplied codec. There is no
/// process-wide registry and therefore no initialization-order dependency.
public interface TomlCodecProvider {
    static func tomlCodec(): TomlAnyCodec
}

private class ErasedTomlCodec<T> <: TomlAnyCodec {
    private let codec: TomlCodec<T>

    init(codec: TomlCodec<T>) { this.codec = codec }

    public func encodeAny(value: Any, context: TomlEncodeContext): TomlOutcome<TomlValue> {
        match (value) {
            case typed: T => codec.encode(typed, context)
            case _ => tomlCodecFailure<TomlValue>("codec_type_mismatch",
                "codec value type does not match its declared type", context.path)
        }
    }

    public func decodeAny(value: TomlValue, context: TomlDecodeContext): TomlOutcome<Any> {
        match (codec.decode(value, context)) {
            case TomlOutcome<T>.Success(decoded, diagnostics) =>
                TomlOutcome<Any>.Success(decoded, diagnostics)
            case TomlOutcome<T>.Failure(diagnostics) => TomlOutcome<Any>.Failure(diagnostics)
        }
    }

    func typed(): TomlCodec<T> { codec }
}

private class ReifiedTomlCodec<T> <: TomlCodec<T> {
    private let codec: TomlAnyCodec

    init(codec: TomlAnyCodec) { this.codec = codec }

    public func encode(value: T, context: TomlEncodeContext): TomlOutcome<TomlValue> {
        codec.encodeAny(value, context)
    }

    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<T> {
        match (codec.decodeAny(value, context)) {
            case TomlOutcome<Any>.Success(decoded, diagnostics) =>
                match (decoded) {
                    case typed: T => TomlOutcome<T>.Success(typed, diagnostics)
                    case _ => tomlCodecFailure<T>("codec_type_mismatch",
                        "decoded value does not match its declared type", context.path)
                }
            case TomlOutcome<Any>.Failure(diagnostics) => TomlOutcome<T>.Failure(diagnostics)
        }
    }
}

public func eraseTomlCodec<T>(codec: TomlCodec<T>): TomlAnyCodec { ErasedTomlCodec(codec) }

public func tomlCodecOf<T>(): TomlCodec<T> where T <: TomlCodecProvider {
    let erased = T.tomlCodec()
    match (erased) {
        case typed: ErasedTomlCodec<T> => typed.typed()
        case _ => ReifiedTomlCodec<T>(erased)
    }
}

public func encodeTomlValue<T>(
    value: T,
    codec: TomlEncode<T>,
    options!: TomlCodecOptions = TomlCodecOptions.defaults
): TomlOutcome<TomlValue> {
    codec.encode(value, TomlEncodeContext(options: options))
}

public func decodeTomlValue<T>(
    value: TomlValue,
    codec: TomlDecode<T>,
    options!: TomlCodecOptions = TomlCodecOptions.defaults
): TomlOutcome<T> {
    codec.decode(value, TomlDecodeContext(options: options))
}

public func encodeTomlValue<T>(
    value: T,
    options!: TomlCodecOptions = TomlCodecOptions.defaults
): TomlOutcome<TomlValue> where T <: TomlCodecProvider {
    tomlCodecOf<T>().encode(value, TomlEncodeContext(options: options))
}

public func decodeTomlValue<T>(
    value: TomlValue,
    options!: TomlCodecOptions = TomlCodecOptions.defaults
): TomlOutcome<T> where T <: TomlCodecProvider {
    tomlCodecOf<T>().decode(value, TomlDecodeContext(options: options))
}

public func decodeTomlWith<T>(
    text: String,
    codec: TomlDecode<T>,
    parseOptions!: TomlParseOptions = TomlParseOptions.defaults,
    codecOptions!: TomlCodecOptions = TomlCodecOptions.defaults
): TomlOutcome<T> {
    match (parseToml(text, options: parseOptions)) {
        case TomlOutcome<TomlTable>.Success(root, parseDiagnostics) =>
            match (codec.decode(root, TomlDecodeContext(options: codecOptions))) {
                case TomlOutcome<T>.Success(value, codecDiagnostics) =>
                    let all = parseDiagnostics.clone()
                    all.add(all: codecDiagnostics)
                    TomlOutcome<T>.Success(value, all)
                case TomlOutcome<T>.Failure(codecDiagnostics) =>
                    let all = parseDiagnostics.clone()
                    all.add(all: codecDiagnostics)
                    TomlOutcome<T>.Failure(all)
            }
        case TomlOutcome<TomlTable>.Failure(diagnostics) => TomlOutcome<T>.Failure(diagnostics)
    }
}

public func encodeTomlWith<T>(
    value: T,
    codec: TomlEncode<T>,
    codecOptions!: TomlCodecOptions = TomlCodecOptions.defaults,
    encodeOptions!: TomlEncodeOptions = TomlEncodeOptions.defaults
): TomlOutcome<String> {
    match (codec.encode(value, TomlEncodeContext(options: codecOptions))) {
        case TomlOutcome<TomlValue>.Success(encoded, codecDiagnostics) =>
            match (encoded) {
                case table: TomlTable =>
                    match (encodeToml(table, options: encodeOptions)) {
                        case TomlOutcome<String>.Success(text, encodeDiagnostics) =>
                            let all = codecDiagnostics.clone()
                            all.add(all: encodeDiagnostics)
                            TomlOutcome<String>.Success(text, all)
                        case TomlOutcome<String>.Failure(encodeDiagnostics) =>
                            let all = codecDiagnostics.clone()
                            all.add(all: encodeDiagnostics)
                            TomlOutcome<String>.Failure(all)
                    }
                case _ => tomlCodecFailure<String>("root_not_table",
                    "a typed TOML document must encode to a table", TomlPath())
            }
        case TomlOutcome<TomlValue>.Failure(diagnostics) => TomlOutcome<String>.Failure(diagnostics)
    }
}

public func decodeToml<T>(
    text: String,
    parseOptions!: TomlParseOptions = TomlParseOptions.defaults,
    codecOptions!: TomlCodecOptions = TomlCodecOptions.defaults
): TomlOutcome<T> where T <: TomlCodecProvider {
    decodeTomlWith(text, tomlCodecOf<T>(), parseOptions: parseOptions, codecOptions: codecOptions)
}

public func encodeToml<T>(
    value: T,
    codecOptions!: TomlCodecOptions = TomlCodecOptions.defaults,
    encodeOptions!: TomlEncodeOptions = TomlEncodeOptions.defaults
): TomlOutcome<String> where T <: TomlCodecProvider {
    encodeTomlWith(value, tomlCodecOf<T>(), codecOptions: codecOptions, encodeOptions: encodeOptions)
}

func tomlCodecSuccess<T>(value: T): TomlOutcome<T> {
    TomlOutcome<T>.Success(value, ArrayList<TomlDiagnostic>())
}

func tomlCodecFailure<T>(code: String, message: String, path: TomlPath): TomlOutcome<T> {
    let diagnostics = ArrayList<TomlDiagnostic>()
    diagnostics.add(TomlDiagnostic(code, TomlSeverity.Error, message, path: Some(path)))
    TomlOutcome<T>.Failure(diagnostics)
}

private func tomlCodecDepthFailure<T>(path: TomlPath): TomlOutcome<T> {
    tomlCodecFailure<T>("codec_depth_limit", "codec nesting exceeds the configured limit", path)
}

private class TomlStringCodec <: TomlCodec<String> {
    public func encode(value: String, _context: TomlEncodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        tomlCodecSuccess<TomlValue>(TomlString(value))
    }
    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<String> {
        match (value) {
            case item: TomlString => tomlCodecSuccess<String>(item.value)
            case _ => tomlCodecFailure<String>("type_mismatch", "expected a TOML string", context.path)
        }
    }
}

private class TomlBoolCodec <: TomlCodec<Bool> {
    public func encode(value: Bool, _context: TomlEncodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        tomlCodecSuccess<TomlValue>(TomlBoolean(value))
    }
    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<Bool> {
        match (value) {
            case item: TomlBoolean => tomlCodecSuccess<Bool>(item.value)
            case _ => tomlCodecFailure<Bool>("type_mismatch", "expected a TOML boolean", context.path)
        }
    }
}

private class TomlBigIntCodec <: TomlCodec<BigInt> {
    public func encode(value: BigInt, _context: TomlEncodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        tomlCodecSuccess<TomlValue>(TomlInteger(value))
    }
    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<BigInt> {
        match (value) {
            case item: TomlInteger => tomlCodecSuccess<BigInt>(item.value)
            case _ => tomlCodecFailure<BigInt>("type_mismatch", "expected a TOML integer", context.path)
        }
    }
}

private class TomlInt64Codec <: TomlCodec<Int64> {
    public func encode(value: Int64, _context: TomlEncodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        tomlCodecSuccess<TomlValue>(TomlInteger(value))
    }
    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<Int64> {
        match (value) {
            case item: TomlInteger =>
                try {
                    tomlCodecSuccess<Int64>(Int64.parse(item.value.toString()))
                } catch (_: Exception) {
                    tomlCodecFailure<Int64>("integer_out_of_range", "integer does not fit Int64", context.path)
                }
            case _ => tomlCodecFailure<Int64>("type_mismatch", "expected a TOML integer", context.path)
        }
    }
}

private class TomlTextIntegerCodec<T> <: TomlCodec<T> {
    private let render: (T) -> String
    private let parseValue: (String) -> T
    private let typeName: String

    init(render: (T) -> String, parseValue: (String) -> T, typeName: String) {
        this.render = render
        this.parseValue = parseValue
        this.typeName = typeName
    }

    public func encode(value: T, _context: TomlEncodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        tomlCodecSuccess<TomlValue>(TomlInteger(BigInt.parse(render(value))))
    }

    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<T> {
        match (value) {
            case item: TomlInteger =>
                try { tomlCodecSuccess<T>(parseValue(item.value.toString())) }
                catch (_: Exception) {
                    tomlCodecFailure<T>("integer_out_of_range", "integer does not fit ${typeName}", context.path)
                }
            case _ => tomlCodecFailure<T>("type_mismatch", "expected a TOML integer", context.path)
        }
    }
}

private class TomlFloat32Codec <: TomlCodec<Float32> {
    public func encode(value: Float32, _context: TomlEncodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        tomlCodecSuccess<TomlValue>(TomlFloat(Float64(value)))
    }
    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<Float32> {
        match (value) {
            case item: TomlFloat =>
                try { tomlCodecSuccess<Float32>(Float32.parse(item.value.toString())) }
                catch (_: Exception) {
                    tomlCodecFailure<Float32>("float_out_of_range", "float does not fit Float32", context.path)
                }
            case _ => tomlCodecFailure<Float32>("type_mismatch", "expected a TOML float", context.path)
        }
    }
}

private class TomlFloat64Codec <: TomlCodec<Float64> {
    public func encode(value: Float64, _context: TomlEncodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        tomlCodecSuccess<TomlValue>(TomlFloat(value))
    }
    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<Float64> {
        match (value) {
            case item: TomlFloat => tomlCodecSuccess<Float64>(item.value)
            case _ => tomlCodecFailure<Float64>("type_mismatch", "expected a TOML float", context.path)
        }
    }
}

private class TomlValueIdentityCodec <: TomlCodec<TomlValue> {
    public func encode(value: TomlValue, _context: TomlEncodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        tomlCodecSuccess<TomlValue>(value.deepCopy())
    }
    public func decode(value: TomlValue, _context: TomlDecodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        tomlCodecSuccess<TomlValue>(value.deepCopy())
    }
}

private class TomlLocalDateCodec <: TomlCodec<TomlLocalDate> {
    public func encode(value: TomlLocalDate, _context: TomlEncodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        tomlCodecSuccess<TomlValue>(value.copyValue())
    }
    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<TomlLocalDate> {
        match (value) {
            case item: TomlLocalDate => tomlCodecSuccess<TomlLocalDate>(item.copyValue())
            case _ => tomlCodecFailure<TomlLocalDate>("type_mismatch", "expected a TOML local date", context.path)
        }
    }
}

private class TomlLocalTimeCodec <: TomlCodec<TomlLocalTime> {
    public func encode(value: TomlLocalTime, _context: TomlEncodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        tomlCodecSuccess<TomlValue>(value.copyValue())
    }
    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<TomlLocalTime> {
        match (value) {
            case item: TomlLocalTime => tomlCodecSuccess<TomlLocalTime>(item.copyValue())
            case _ => tomlCodecFailure<TomlLocalTime>("type_mismatch", "expected a TOML local time", context.path)
        }
    }
}

private class TomlLocalDateTimeCodec <: TomlCodec<TomlLocalDateTime> {
    public func encode(value: TomlLocalDateTime, _context: TomlEncodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        tomlCodecSuccess<TomlValue>(value.copyValue())
    }
    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<TomlLocalDateTime> {
        match (value) {
            case item: TomlLocalDateTime => tomlCodecSuccess<TomlLocalDateTime>(item.copyValue())
            case _ => tomlCodecFailure<TomlLocalDateTime>("type_mismatch", "expected a TOML local date-time", context.path)
        }
    }
}

private class TomlOffsetDateTimeCodec <: TomlCodec<TomlOffsetDateTime> {
    public func encode(value: TomlOffsetDateTime, _context: TomlEncodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        tomlCodecSuccess<TomlValue>(value.copyValue())
    }
    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<TomlOffsetDateTime> {
        match (value) {
            case item: TomlOffsetDateTime => tomlCodecSuccess<TomlOffsetDateTime>(item.copyValue())
            case _ => tomlCodecFailure<TomlOffsetDateTime>("type_mismatch", "expected a TOML offset date-time", context.path)
        }
    }
}

private class TomlDateTimeCodec <: TomlCodec<DateTime> {
    public func encode(value: DateTime, _context: TomlEncodeContext): TomlOutcome<TomlValue> {
        let _ = _context
        match (TomlOffsetDateTime.fromDateTime(value)) {
            case TomlOutcome<TomlOffsetDateTime>.Success(item, diagnostics) =>
                TomlOutcome<TomlValue>.Success(item, diagnostics)
            case TomlOutcome<TomlOffsetDateTime>.Failure(diagnostics) =>
                TomlOutcome<TomlValue>.Failure(diagnostics)
        }
    }
    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<DateTime> {
        match (value) {
            case item: TomlOffsetDateTime => item.toDateTime()
            case _ => tomlCodecFailure<DateTime>("type_mismatch", "expected a TOML offset date-time", context.path)
        }
    }
}

private class TomlArrayCodec<T> <: TomlCodec<Array<T>> {
    private let element: TomlCodec<T>
    init(element: TomlCodec<T>) { this.element = element }

    public func encode(value: Array<T>, context: TomlEncodeContext): TomlOutcome<TomlValue> {
        if (context.depth >= context.options.maxDepth) { return tomlCodecDepthFailure<TomlValue>(context.path) }
        let result = TomlArray()
        let diagnostics = ArrayList<TomlDiagnostic>()
        var failed = false
        for (index in 0..value.size) {
            match (element.encode(value[index], context.atIndex(index))) {
                case TomlOutcome<TomlValue>.Success(item, itemDiagnostics) =>
                    diagnostics.add(all: itemDiagnostics)
                    result.add(item)
                case TomlOutcome<TomlValue>.Failure(itemDiagnostics) =>
                    diagnostics.add(all: itemDiagnostics)
                    failed = true
                    if (!context.options.aggregateErrors) { return TomlOutcome<TomlValue>.Failure(diagnostics) }
            }
        }
        if (failed) { TomlOutcome<TomlValue>.Failure(diagnostics) }
        else { TomlOutcome<TomlValue>.Success(result, diagnostics) }
    }

    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<Array<T>> {
        if (context.depth >= context.options.maxDepth) { return tomlCodecDepthFailure<Array<T>>(context.path) }
        match (value) {
            case input: TomlArray =>
                let result = ArrayList<T>()
                let diagnostics = ArrayList<TomlDiagnostic>()
                var failed = false
                for (index in 0..input.size) {
                    match (element.decode(input[index], context.atIndex(index))) {
                        case TomlOutcome<T>.Success(item, itemDiagnostics) =>
                            diagnostics.add(all: itemDiagnostics)
                            result.add(item)
                        case TomlOutcome<T>.Failure(itemDiagnostics) =>
                            diagnostics.add(all: itemDiagnostics)
                            failed = true
                            if (!context.options.aggregateErrors) {
                                return TomlOutcome<Array<T>>.Failure(diagnostics)
                            }
                    }
                }
                if (failed) { TomlOutcome<Array<T>>.Failure(diagnostics) }
                else { TomlOutcome<Array<T>>.Success(result.toArray(), diagnostics) }
            case _ => tomlCodecFailure<Array<T>>("type_mismatch", "expected a TOML array", context.path)
        }
    }
}

private class TomlArrayListCodec<T> <: TomlCodec<ArrayList<T>> {
    private let arrayCodec: TomlCodec<Array<T>>
    init(element: TomlCodec<T>) { arrayCodec = TomlArrayCodec<T>(element) }

    public func encode(value: ArrayList<T>, context: TomlEncodeContext): TomlOutcome<TomlValue> {
        arrayCodec.encode(value.toArray(), context)
    }
    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<ArrayList<T>> {
        match (arrayCodec.decode(value, context)) {
            case TomlOutcome<Array<T>>.Success(items, diagnostics) =>
                TomlOutcome<ArrayList<T>>.Success(ArrayList<T>(items), diagnostics)
            case TomlOutcome<Array<T>>.Failure(diagnostics) =>
                TomlOutcome<ArrayList<T>>.Failure(diagnostics)
        }
    }
}

private class TomlStringMapCodec<T> <: TomlCodec<HashMap<String, T>> {
    private let element: TomlCodec<T>
    init(element: TomlCodec<T>) { this.element = element }

    public func encode(value: HashMap<String, T>, context: TomlEncodeContext): TomlOutcome<TomlValue> {
        if (context.depth >= context.options.maxDepth) { return tomlCodecDepthFailure<TomlValue>(context.path) }
        let result = TomlTable(inline: true)
        let diagnostics = ArrayList<TomlDiagnostic>()
        var failed = false
        for ((key, item) in value) {
            match (element.encode(item, context.atKey(key))) {
                case TomlOutcome<TomlValue>.Success(encoded, itemDiagnostics) =>
                    diagnostics.add(all: itemDiagnostics)
                    result.put(key, encoded)
                case TomlOutcome<TomlValue>.Failure(itemDiagnostics) =>
                    diagnostics.add(all: itemDiagnostics)
                    failed = true
                    if (!context.options.aggregateErrors) { return TomlOutcome<TomlValue>.Failure(diagnostics) }
            }
        }
        if (failed) { TomlOutcome<TomlValue>.Failure(diagnostics) }
        else { TomlOutcome<TomlValue>.Success(result, diagnostics) }
    }

    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<HashMap<String, T>> {
        if (context.depth >= context.options.maxDepth) {
            return tomlCodecDepthFailure<HashMap<String, T>>(context.path)
        }
        match (value) {
            case input: TomlTable =>
                let result = HashMap<String, T>()
                let diagnostics = ArrayList<TomlDiagnostic>()
                var failed = false
                for (key in input.keys()) {
                    match (element.decode(input[key], context.atKey(key))) {
                        case TomlOutcome<T>.Success(item, itemDiagnostics) =>
                            diagnostics.add(all: itemDiagnostics)
                            let _ = result.add(key, item)
                        case TomlOutcome<T>.Failure(itemDiagnostics) =>
                            diagnostics.add(all: itemDiagnostics)
                            failed = true
                            if (!context.options.aggregateErrors) {
                                return TomlOutcome<HashMap<String, T>>.Failure(diagnostics)
                            }
                    }
                }
                if (failed) { TomlOutcome<HashMap<String, T>>.Failure(diagnostics) }
                else { TomlOutcome<HashMap<String, T>>.Success(result, diagnostics) }
            case _ => tomlCodecFailure<HashMap<String, T>>("type_mismatch", "expected a TOML table", context.path)
        }
    }
}

private class TomlOptionCodec<T> <: TomlCodec<Option<T>> {
    private let inner: TomlCodec<T>
    init(inner: TomlCodec<T>) { this.inner = inner }

    public func encode(value: Option<T>, context: TomlEncodeContext): TomlOutcome<TomlValue> {
        match (value) {
            case Some(item) => inner.encode(item, context)
            case None => tomlCodecFailure<TomlValue>("none_not_representable",
                "TOML has no null value; omit an absent optional field", context.path)
        }
    }

    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<Option<T>> {
        match (inner.decode(value, context)) {
            case TomlOutcome<T>.Success(item, diagnostics) =>
                TomlOutcome<Option<T>>.Success(Some(item), diagnostics)
            case TomlOutcome<T>.Failure(diagnostics) => TomlOutcome<Option<T>>.Failure(diagnostics)
        }
    }
}

/// Built-in codecs are immutable singleton values or immutable generic
/// composites. Applications pass them explicitly or expose them via a provider.
public class TomlCodecs {
    public static let string: TomlCodec<String> = TomlStringCodec()
    public static let bool: TomlCodec<Bool> = TomlBoolCodec()
    public static let int64: TomlCodec<Int64> = TomlInt64Codec()
    public static let int32: TomlCodec<Int32> = TomlTextIntegerCodec<Int32>(
        { value => value.toString() }, { text => Int32.parse(text) }, "Int32")
    public static let int16: TomlCodec<Int16> = TomlTextIntegerCodec<Int16>(
        { value => value.toString() }, { text => Int16.parse(text) }, "Int16")
    public static let int8: TomlCodec<Int8> = TomlTextIntegerCodec<Int8>(
        { value => value.toString() }, { text => Int8.parse(text) }, "Int8")
    public static let uint64: TomlCodec<UInt64> = TomlTextIntegerCodec<UInt64>(
        { value => value.toString() }, { text => UInt64.parse(text) }, "UInt64")
    public static let uint32: TomlCodec<UInt32> = TomlTextIntegerCodec<UInt32>(
        { value => value.toString() }, { text => UInt32.parse(text) }, "UInt32")
    public static let uint16: TomlCodec<UInt16> = TomlTextIntegerCodec<UInt16>(
        { value => value.toString() }, { text => UInt16.parse(text) }, "UInt16")
    public static let uint8: TomlCodec<UInt8> = TomlTextIntegerCodec<UInt8>(
        { value => value.toString() }, { text => UInt8.parse(text) }, "UInt8")
    public static let bigInt: TomlCodec<BigInt> = TomlBigIntCodec()
    public static let float64: TomlCodec<Float64> = TomlFloat64Codec()
    public static let float32: TomlCodec<Float32> = TomlFloat32Codec()
    public static let value: TomlCodec<TomlValue> = TomlValueIdentityCodec()
    public static let localDate: TomlCodec<TomlLocalDate> = TomlLocalDateCodec()
    public static let localTime: TomlCodec<TomlLocalTime> = TomlLocalTimeCodec()
    public static let localDateTime: TomlCodec<TomlLocalDateTime> = TomlLocalDateTimeCodec()
    public static let offsetDateTime: TomlCodec<TomlOffsetDateTime> = TomlOffsetDateTimeCodec()
    public static let dateTime: TomlCodec<DateTime> = TomlDateTimeCodec()

    public static func array<T>(element: TomlCodec<T>): TomlCodec<Array<T>> {
        TomlArrayCodec<T>(element)
    }

    public static func arrayList<T>(element: TomlCodec<T>): TomlCodec<ArrayList<T>> {
        TomlArrayListCodec<T>(element)
    }

    public static func stringMap<T>(element: TomlCodec<T>): TomlCodec<HashMap<String, T>> {
        TomlStringMapCodec<T>(element)
    }

    public static func option<T>(inner: TomlCodec<T>): TomlCodec<Option<T>> {
        TomlOptionCodec<T>(inner)
    }
}
