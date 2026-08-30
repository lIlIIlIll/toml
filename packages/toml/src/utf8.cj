// SPDX-License-Identifier: Apache-2.0
package toml

// Returns 0 for an invalid sequence, otherwise the exact UTF-8 sequence width.
func tomlValidUtf8Width(bytes: Array<Byte>, index: Int64): Int64 {
    let first = bytes[index]
    if (first <= 0x7F) { return 1 }
    if (first >= 0xC2 && first <= 0xDF) {
        if (index + 1 < bytes.size && tomlContinuation(bytes[index + 1])) { return 2 }
        return 0
    }
    if (first == 0xE0) {
        if (index + 2 < bytes.size && bytes[index + 1] >= 0xA0 && bytes[index + 1] <= 0xBF &&
            tomlContinuation(bytes[index + 2])) { return 3 }
        return 0
    }
    if (first >= 0xE1 && first <= 0xEC) {
        if (index + 2 < bytes.size && tomlContinuation(bytes[index + 1]) &&
            tomlContinuation(bytes[index + 2])) { return 3 }
        return 0
    }
    if (first == 0xED) {
        if (index + 2 < bytes.size && bytes[index + 1] >= 0x80 && bytes[index + 1] <= 0x9F &&
            tomlContinuation(bytes[index + 2])) { return 3 }
        return 0
    }
    if (first >= 0xEE && first <= 0xEF) {
        if (index + 2 < bytes.size && tomlContinuation(bytes[index + 1]) &&
            tomlContinuation(bytes[index + 2])) { return 3 }
        return 0
    }
    if (first == 0xF0) {
        if (index + 3 < bytes.size && bytes[index + 1] >= 0x90 && bytes[index + 1] <= 0xBF &&
            tomlContinuation(bytes[index + 2]) && tomlContinuation(bytes[index + 3])) { return 4 }
        return 0
    }
    if (first >= 0xF1 && first <= 0xF3) {
        if (index + 3 < bytes.size && tomlContinuation(bytes[index + 1]) &&
            tomlContinuation(bytes[index + 2]) && tomlContinuation(bytes[index + 3])) { return 4 }
        return 0
    }
    if (first == 0xF4) {
        if (index + 3 < bytes.size && bytes[index + 1] >= 0x80 && bytes[index + 1] <= 0x8F &&
            tomlContinuation(bytes[index + 2]) && tomlContinuation(bytes[index + 3])) { return 4 }
        return 0
    }
    0
}

private func tomlContinuation(byte: Byte): Bool { byte >= 0x80 && byte <= 0xBF }

func tomlDecodeCodePoint(bytes: Array<Byte>, index: Int64, width: Int64): UInt32 {
    if (width == 1) { return UInt32(bytes[index]) }
    if (width == 2) {
        return (UInt32(bytes[index] & 0x1F) << 6) | UInt32(bytes[index + 1] & 0x3F)
    }
    if (width == 3) {
        return (UInt32(bytes[index] & 0x0F) << 12) |
            (UInt32(bytes[index + 1] & 0x3F) << 6) | UInt32(bytes[index + 2] & 0x3F)
    }
    (UInt32(bytes[index] & 0x07) << 18) |
        (UInt32(bytes[index + 1] & 0x3F) << 12) |
        (UInt32(bytes[index + 2] & 0x3F) << 6) | UInt32(bytes[index + 3] & 0x3F)
}

func tomlDecodeUtf8(bytes: Array<Byte>, start: Int64, end: Int64, replaceInvalid: Bool): String {
    let out = StringBuilder()
    var index = start
    while (index < end) {
        let width = tomlValidUtf8Width(bytes, index)
        if (width == 0 || index + width > end) {
            if (!replaceInvalid) { throw IllegalArgumentException("invalid UTF-8") }
            out.append(r'\u{FFFD}')
            index++
        } else {
            out.append(Rune(tomlDecodeCodePoint(bytes, index, width)))
            index += width
        }
    }
    out.toString()
}

func tomlAppendCodePoint(out: StringBuilder, value: UInt32): Bool {
    if (value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) { return false }
    out.append(Rune(value))
    true
}

func tomlHexDigit(byte: Byte): Int64 {
    if (byte >= b'0' && byte <= b'9') { return Int64(byte - b'0') }
    if (byte >= b'a' && byte <= b'f') { return Int64(byte - b'a') + 10 }
    if (byte >= b'A' && byte <= b'F') { return Int64(byte - b'A') + 10 }
    -1
}

func tomlIsAsciiDigit(byte: Byte): Bool { byte >= b'0' && byte <= b'9' }

func tomlCloneStringBytes(value: String): Array<Byte> {
    unsafe { value.rawData().clone() }
}
