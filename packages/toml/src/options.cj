// SPDX-License-Identifier: Apache-2.0
package toml

public enum TomlVersion {
    V1_0 | V1_1
}

public enum TomlUtf8Policy {
    Reject | ReplaceInvalid
}

public enum TomlIntegerMode {
    PortableInt64 | ArbitraryPrecision
}

public enum TomlNewline {
    Lf | CrLf
}

public class TomlLimits {
    public let maxInputBytes: Int64
    public let maxDepth: Int64
    public let maxKeySegments: Int64
    public let maxDiagnostics: Int64
    public let maxTokens: Int64
    public let maxNodes: Int64

    public init(
        maxInputBytes!: Int64 = 16 * 1024 * 1024,
        maxDepth!: Int64 = 256,
        maxKeySegments!: Int64 = 256,
        maxDiagnostics!: Int64 = 100,
        maxTokens!: Int64 = 2_000_000,
        maxNodes!: Int64 = 2_000_000
    ) {
        if (maxInputBytes <= 0 || maxDepth <= 0 || maxKeySegments <= 0 ||
            maxDiagnostics <= 0 || maxTokens <= 0 || maxNodes <= 0) {
            throw IllegalArgumentException("all TOML limits must be positive")
        }
        this.maxInputBytes = maxInputBytes
        this.maxDepth = maxDepth
        this.maxKeySegments = maxKeySegments
        this.maxDiagnostics = maxDiagnostics
        this.maxTokens = maxTokens
        this.maxNodes = maxNodes
    }

    public static let defaults: TomlLimits = TomlLimits()
}

public class TomlParseOptions {
    public let version: TomlVersion
    public let utf8Policy: TomlUtf8Policy
    public let integerMode: TomlIntegerMode
    public let allowBom: Bool
    public let limits: TomlLimits

    public init(
        version!: TomlVersion = TomlVersion.V1_1,
        utf8Policy!: TomlUtf8Policy = TomlUtf8Policy.Reject,
        integerMode!: TomlIntegerMode = TomlIntegerMode.PortableInt64,
        allowBom!: Bool = true,
        limits!: TomlLimits = TomlLimits.defaults
    ) {
        this.version = version
        this.utf8Policy = utf8Policy
        this.integerMode = integerMode
        this.allowBom = allowBom
        this.limits = limits
    }

    public static let defaults: TomlParseOptions = TomlParseOptions()
    public static let strict10: TomlParseOptions = TomlParseOptions(version: TomlVersion.V1_0)
    public static let strict11: TomlParseOptions = TomlParseOptions(version: TomlVersion.V1_1)
}

public class TomlStyle {
    public let indent: String
    public let maxWidth: Int64
    public let newline: TomlNewline
    public let finalNewline: Bool

    public init(
        indent!: String = "  ",
        maxWidth!: Int64 = 100,
        newline!: TomlNewline = TomlNewline.Lf,
        finalNewline!: Bool = true
    ) {
        if (indent.isEmpty()) { throw IllegalArgumentException("indent must not be empty") }
        if (maxWidth < 20) { throw IllegalArgumentException("maxWidth must be at least 20") }
        this.indent = indent
        this.maxWidth = maxWidth
        this.newline = newline
        this.finalNewline = finalNewline
    }

    public static let readable: TomlStyle = TomlStyle()
    public static let canonical: TomlStyle = TomlStyle(indent: "  ", maxWidth: 80,
        newline: TomlNewline.Lf, finalNewline: true)
}

public class TomlEncodeOptions {
    public let version: TomlVersion
    public let integerMode: TomlIntegerMode
    public let style: TomlStyle

    public init(
        version!: TomlVersion = TomlVersion.V1_1,
        integerMode!: TomlIntegerMode = TomlIntegerMode.PortableInt64,
        style!: TomlStyle = TomlStyle.readable
    ) {
        this.version = version
        this.integerMode = integerMode
        this.style = style
    }

    public static let defaults: TomlEncodeOptions = TomlEncodeOptions()
}
