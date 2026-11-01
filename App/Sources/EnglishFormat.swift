import Foundation

enum EnglishFormat {
    static var locale: Locale {
        Locale(identifier: "en_US")
    }

    static func number(_ value: Int) -> String {
        decimal(value: Double(value), maximumFractionDigits: 0)
    }

    static func duration(seconds: Int) -> String {
        let totalSeconds = max(0, seconds)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60

        switch (minutes, remainingSeconds) {
        case (0, _):
            return "\(number(remainingSeconds)) sec"
        case (_, 0):
            return "\(number(minutes)) min"
        default:
            return "\(number(minutes)) min \(number(remainingSeconds)) sec"
        }
    }

    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func byteCount(_ value: Int64) -> String {
        let bytes = max(0, value)
        let units: [(divisor: Int64, label: String)] = [
            (1_000_000_000_000_000, "PB"),
            (1_000_000_000_000, "TB"),
            (1_000_000_000, "GB"),
            (1_000_000, "MB"),
            (1_000, "KB"),
            (1, "bytes")
        ]
        var unitIndex = units.count - 1

        for index in units.indices where bytes >= units[index].divisor {
            unitIndex = index
            break
        }
        if unitIndex > units.startIndex,
           Double(bytes) / Double(units[unitIndex].divisor) >= 999.95 {
            unitIndex -= 1
        }

        let unit = units[unitIndex]
        return "\(decimal(value: Double(bytes) / Double(unit.divisor), maximumFractionDigits: 1)) \(unit.label)"
    }

    private static func decimal(value: Double, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
