// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*
import std.convert.Parsable
import std.time.*

public class TomlLocalDate <: TomlValue & Equatable<TomlLocalDate> {
    public let year: Int64
    public let month: Int64
    public let day: Int64

    public init(year: Int64, month: Int64, day: Int64) {
        if (year < 0 || year > 9999 || month < 1 || month > 12 ||
            day < 1 || day > tomlDaysInMonth(year, month)) {
            throw IllegalArgumentException("invalid TOML local date")
        }
        this.year = year
        this.month = month
        this.day = day
    }

    public func kind(): TomlKind { TomlKind.LocalDate }
    public func copyValue(): TomlLocalDate { TomlLocalDate(year, month, day) }

    public operator func ==(other: TomlLocalDate): Bool {
        year == other.year && month == other.month && day == other.day
    }

    public operator func !=(other: TomlLocalDate): Bool { !(this == other) }
    public func toString(): String { "${tomlFourDigits(year)}-${tomlTwoDigits(month)}-${tomlTwoDigits(day)}" }
}

public class TomlLocalTime <: TomlValue & Equatable<TomlLocalTime> {
    public let hour: Int64
    public let minute: Int64
    public let second: Int64
    /// Exact decimal fraction digits, normalized by removing trailing zeroes.
    public let fraction: String

    public init(hour: Int64, minute: Int64, second!: Int64 = 0, fraction!: String = "") {
        if (hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) {
            throw IllegalArgumentException("invalid TOML local time")
        }
        for (byte in unsafe { fraction.rawData() }) {
            if (byte < b'0' || byte > b'9') {
                throw IllegalArgumentException("time fraction must contain decimal digits only")
            }
        }
        this.hour = hour
        this.minute = minute
        this.second = second
        this.fraction = tomlNormalizeFraction(fraction)
    }

    public func kind(): TomlKind { TomlKind.LocalTime }
    public func copyValue(): TomlLocalTime { TomlLocalTime(hour, minute, second: second, fraction: fraction) }

    public operator func ==(other: TomlLocalTime): Bool {
        hour == other.hour && minute == other.minute && second == other.second && fraction == other.fraction
    }

    public operator func !=(other: TomlLocalTime): Bool { !(this == other) }

    public func toString(): String {
        let base = "${tomlTwoDigits(hour)}:${tomlTwoDigits(minute)}:${tomlTwoDigits(second)}"
        if (fraction.isEmpty()) { base } else { "${base}.${fraction}" }
    }
}

public class TomlLocalDateTime <: TomlValue & Equatable<TomlLocalDateTime> {
    public let date: TomlLocalDate
    public let time: TomlLocalTime

    public init(date: TomlLocalDate, time: TomlLocalTime) {
        this.date = date.copyValue()
        this.time = time.copyValue()
    }

    public init(
        year: Int64, month: Int64, day: Int64,
        hour: Int64, minute: Int64,
        second!: Int64 = 0, fraction!: String = ""
    ) {
        date = TomlLocalDate(year, month, day)
        time = TomlLocalTime(hour, minute, second: second, fraction: fraction)
    }

    public func kind(): TomlKind { TomlKind.LocalDateTime }
    public func copyValue(): TomlLocalDateTime { TomlLocalDateTime(date, time) }

    public operator func ==(other: TomlLocalDateTime): Bool {
        date == other.date && time == other.time
    }

    public operator func !=(other: TomlLocalDateTime): Bool { !(this == other) }
    public func toString(): String { "${date}T${time}" }
}

public class TomlOffsetDateTime <: TomlValue & Equatable<TomlOffsetDateTime> {
    public let local: TomlLocalDateTime
    /// Signed offset from UTC in minutes.
    public let offsetMinutes: Int64

    public init(local: TomlLocalDateTime, offsetMinutes: Int64) {
        if (offsetMinutes < -(23 * 60 + 59) || offsetMinutes > 23 * 60 + 59) {
            throw IllegalArgumentException("TOML offset must be between -23:59 and +23:59")
        }
        this.local = local.copyValue()
        this.offsetMinutes = offsetMinutes
    }

    public func kind(): TomlKind { TomlKind.OffsetDateTime }
    public func copyValue(): TomlOffsetDateTime { TomlOffsetDateTime(local, offsetMinutes) }

    public operator func ==(other: TomlOffsetDateTime): Bool {
        local == other.local && offsetMinutes == other.offsetMinutes
    }

    public operator func !=(other: TomlOffsetDateTime): Bool { !(this == other) }

    public func sameInstant(other: TomlOffsetDateTime): Bool {
        tomlEpochSecond(this) == tomlEpochSecond(other) && local.time.fraction == other.local.time.fraction
    }

    /// Converts to std.time.DateTime without silently truncating exact TOML
    /// fractions. DateTime supports at most nanosecond precision.
    public func toDateTime(): TomlOutcome<DateTime> {
        if (local.time.fraction.size > 9) {
            let diagnostics = ArrayList<TomlDiagnostic>()
            diagnostics.add(TomlDiagnostic("datetime_precision_loss", TomlSeverity.Error,
                "std.time.DateTime cannot represent more than 9 fractional digits"))
            return TomlOutcome<DateTime>.Failure(diagnostics)
        }
        var fraction = local.time.fraction
        while (fraction.size < 9) { fraction += "0" }
        let nanos = if (fraction.isEmpty()) { 0 } else { Int64.parse(fraction) }
        try {
            let zone = TimeZone(tomlOffsetZoneId(offsetMinutes), Duration.minute * offsetMinutes)
            let value = DateTime.of(
                year: local.date.year,
                month: local.date.month,
                dayOfMonth: local.date.day,
                hour: local.time.hour,
                minute: local.time.minute,
                second: local.time.second,
                nanosecond: nanos,
                timeZone: zone
            )
            TomlOutcome<DateTime>.Success(value, ArrayList<TomlDiagnostic>())
        } catch (exception: Exception) {
            let diagnostics = ArrayList<TomlDiagnostic>()
            diagnostics.add(TomlDiagnostic("datetime_out_of_range", TomlSeverity.Error,
                "cannot convert TOML offset date-time to DateTime: ${exception.message}"))
            TomlOutcome<DateTime>.Failure(diagnostics)
        }
    }

    public static func fromDateTime(value: DateTime): TomlOutcome<TomlOffsetDateTime> {
        let offsetSeconds = value.zoneOffset.toSeconds()
        if (offsetSeconds % 60 != 0) {
            let diagnostics = ArrayList<TomlDiagnostic>()
            diagnostics.add(TomlDiagnostic("datetime_offset_precision", TomlSeverity.Error,
                "TOML offsets have minute precision but DateTime has a sub-minute zone offset"))
            return TomlOutcome<TomlOffsetDateTime>.Failure(diagnostics)
        }
        if (value.year < 0 || value.year > 9999) {
            let diagnostics = ArrayList<TomlDiagnostic>()
            diagnostics.add(TomlDiagnostic("datetime_out_of_range", TomlSeverity.Error,
                "TOML date years must be between 0000 and 9999"))
            return TomlOutcome<TomlOffsetDateTime>.Failure(diagnostics)
        }
        var fraction = tomlNineDigits(value.nanosecond)
        while (fraction.endsWith("0")) { fraction = fraction[0..fraction.size - 1] }
        let localDate = TomlLocalDate(value.year, value.month.toInteger(), value.dayOfMonth)
        let localTime = TomlLocalTime(value.hour, value.minute, second: value.second, fraction: fraction)
        TomlOutcome<TomlOffsetDateTime>.Success(
            TomlOffsetDateTime(TomlLocalDateTime(localDate, localTime), offsetSeconds / 60),
            ArrayList<TomlDiagnostic>()
        )
    }

    public func toString(): String {
        if (offsetMinutes == 0) { return "${local}Z" }
        let sign = if (offsetMinutes < 0) { "-" } else { "+" }
        let magnitude = if (offsetMinutes < 0) { -offsetMinutes } else { offsetMinutes }
        "${local}${sign}${tomlTwoDigits(magnitude / 60)}:${tomlTwoDigits(magnitude % 60)}"
    }
}

private func tomlOffsetZoneId(offsetMinutes: Int64): String {
    if (offsetMinutes == 0) { return "UTC" }
    let sign = if (offsetMinutes < 0) { "-" } else { "+" }
    let absolute = if (offsetMinutes < 0) { -offsetMinutes } else { offsetMinutes }
    "TOML${sign}${tomlTwoDigits(absolute / 60)}:${tomlTwoDigits(absolute % 60)}"
}

private func tomlNineDigits(value: Int64): String {
    let text = value.toString()
    let output = StringBuilder()
    for (_ in 0..(9 - text.size)) { output.append("0") }
    output.append(text)
    output.toString()
}

private func tomlIsLeapYear(year: Int64): Bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

private func tomlDaysInMonth(year: Int64, month: Int64): Int64 {
    match (month) {
        case 1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
        case 4 | 6 | 9 | 11 => 30
        case 2 => if (tomlIsLeapYear(year)) { 29 } else { 28 }
        case _ => 0
    }
}

private func tomlNormalizeFraction(value: String): String {
    if (value.isEmpty()) { return value }
    let bytes = unsafe { value.rawData() }
    var end = bytes.size
    while (end > 0 && bytes[end - 1] == b'0') { end-- }
    if (end == 0) { return "" }
    String.fromUtf8(bytes[0..end])
}

private func tomlTwoDigits(value: Int64): String {
    if (value < 10) { "0${value}" } else { value.toString() }
}

private func tomlFourDigits(value: Int64): String {
    if (value < 10) { "000${value}" }
    else if (value < 100) { "00${value}" }
    else if (value < 1000) { "0${value}" }
    else { value.toString() }
}

// Howard Hinnant's civil-date transform, with a 1970-01-01 epoch.
private func tomlDaysFromCivil(year: Int64, month: Int64, day: Int64): Int64 {
    let adjustedYear = year - if (month <= 2) { 1 } else { 0 }
    let era = if (adjustedYear >= 0) { adjustedYear / 400 } else { (adjustedYear - 399) / 400 }
    let yearOfEra = adjustedYear - era * 400
    let shiftedMonth = month + if (month > 2) { -3 } else { 9 }
    let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    era * 146097 + dayOfEra - 719468
}

private func tomlEpochSecond(value: TomlOffsetDateTime): Int64 {
    let date = value.local.date
    let time = value.local.time
    tomlDaysFromCivil(date.year, date.month, date.day) * 86400 +
        time.hour * 3600 + time.minute * 60 + time.second - value.offsetMinutes * 60
}
