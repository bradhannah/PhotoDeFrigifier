import Foundation

/// Date conventions shared with the photo-date-repair skill and the Amazon migration:
/// - nothing known: 1 Jan 1900, 12:00 (keyword "Undated")
/// - year known: 1 July of that year, 12:00 ("Date approximate")
/// - month known: the 15th, 12:00 ("Date approximate")
/// - day known: that day, 12:00
/// Noon keeps the day stable across time zone changes.
public enum DateRules {
  /// Anything dated before this year is treated as having no real date.
  public static let undatedCutoffYear = 1902

  public static func isUndated(_ date: Date?, calendar: Calendar = .current) -> Bool {
    guard let date else { return true }
    return calendar.component(.year, from: date) < undatedCutoffYear
  }

  /// The placeholder date for a partly known date. Returns nil for an invalid combination (e.g. 31 Feb).
  public static func placeholder(year: Int, month: Int?, day: Int?, calendar: Calendar = .current) -> Date? {
    var c = DateComponents()
    c.year = year
    c.month = month ?? 7
    c.day = day ?? (month == nil ? 1 : 15)
    c.hour = 12
    guard let date = calendar.date(from: c) else { return nil }
    // DateComponents silently rolls 31 Feb into March; reject that instead of saving a surprising date.
    let back = calendar.dateComponents([.year, .month, .day], from: date)
    guard back.year == c.year, back.month == c.month, back.day == c.day else { return nil }
    return date
  }

  /// True when the chosen parts only pin down the year or month (the "Date approximate" case).
  public static func isApproximate(month: Int?, day: Int?) -> Bool { month == nil || day == nil }
}
