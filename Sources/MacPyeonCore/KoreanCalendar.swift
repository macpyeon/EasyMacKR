import Foundation

/// 한국 공휴일과 음력.
///
/// 음력은 Foundation의 중국 음력으로 계산한다. 한국 음력과는 기준 시각(동경 120° / 135°)이 달라
/// 아주 드물게 하루 차이가 날 수 있다. 선거일·임시공휴일은 미리 알 수 없어 넣지 않는다.
public enum KoreanCalendar {
    public struct Holiday: Equatable, Hashable, Sendable {
        public let year: Int
        public let month: Int
        public let day: Int
        public let name: String
        /// 대체공휴일인지.
        public let substitute: Bool

        public init(year: Int, month: Int, day: Int, name: String, substitute: Bool = false) {
            self.year = year
            self.month = month
            self.day = day
            self.name = name
            self.substitute = substitute
        }
    }

    public struct LunarDate: Equatable, Sendable {
        public let month: Int
        public let day: Int
        public let isLeap: Bool

        public var text: String { "\(isLeap ? "윤" : "")\(month).\(day)" }
    }

    private static let seoul = TimeZone(identifier: "Asia/Seoul")!

    static var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = seoul
        return c
    }

    private static var lunar: Calendar {
        var c = Calendar(identifier: .chinese)
        c.timeZone = seoul
        return c
    }

    public static func lunarDate(year: Int, month: Int, day: Int) -> LunarDate? {
        guard let date = gregorian.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else { return nil }
        let c = lunar.dateComponents([.month, .day], from: date)
        guard let m = c.month, let d = c.day else { return nil }
        return LunarDate(month: m, day: d, isLeap: c.isLeapMonth ?? false)
    }

    /// 그 해 양력 날짜 중 음력 month/day(윤달 제외)에 해당하는 날.
    static func solar(ofLunarMonth month: Int, day: Int, inYear year: Int) -> DateComponents? {
        let cal = gregorian
        guard var date = cal.date(from: DateComponents(year: year, month: 1, day: 1, hour: 12)) else { return nil }
        for _ in 0..<366 {
            let c = cal.dateComponents([.year, .month, .day], from: date)
            guard c.year == year else { break }
            let l = lunar.dateComponents([.month, .day], from: date)
            if l.month == month, l.day == day, l.isLeapMonth != true { return c }
            date = cal.date(byAdding: .day, value: 1, to: date)!
        }
        return nil
    }

    private static var cache: [Int: [Holiday]] = [:]
    private static let lock = NSLock()

    /// 그 해의 공휴일(대체공휴일 포함), 날짜순.
    public static func holidays(year: Int) -> [Holiday] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[year] { return cached }
        let result = compute(year: year)
        cache[year] = result
        return result
    }

    public static func holidays(year: Int, month: Int) -> [Holiday] {
        holidays(year: year).filter { $0.month == month }
    }

    public static func holiday(year: Int, month: Int, day: Int) -> [Holiday] {
        holidays(year: year).filter { $0.month == month && $0.day == day }
    }

    private enum SubstituteRule {
        case none
        /// 일요일 또는 다른 공휴일과 겹치면(설·추석).
        case sundayOrOverlap
        /// 토·일요일 또는 다른 공휴일과 겹치면.
        case weekendOrOverlap
    }

    private static func compute(year: Int) -> [Holiday] {
        let cal = gregorian
        typealias Item = (date: Date, name: String, rule: SubstituteRule)
        var items: [Item] = []
        func add(_ c: DateComponents?, _ name: String, _ rule: SubstituteRule) {
            guard let c, let d = cal.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 12)) else { return }
            items.append((d, name, rule))
        }
        func fixed(_ m: Int, _ d: Int) -> DateComponents { DateComponents(year: year, month: m, day: d) }

        // 대체공휴일 적용 범위는 해마다 넓어졌다.
        let weekendRuleFrom3_1 = year >= 2022   // 2021.8 공휴일법 개정 이후 첫 해부터 국경일 확대
        let buddhaChristmas = year >= 2023
        let childrenWeekend = year >= 2014

        add(fixed(1, 1), "신정", .none)
        if let seol = solar(ofLunarMonth: 1, day: 1, inYear: year), let seolDate = cal.date(from: DateComponents(year: seol.year, month: seol.month, day: seol.day, hour: 12)) {
            let rule: SubstituteRule = year >= 2014 ? .sundayOrOverlap : .none
            add(cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: -1, to: seolDate)!), "설날 연휴", rule)
            add(seol, "설날", rule)
            add(cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: 1, to: seolDate)!), "설날 연휴", rule)
        }
        add(fixed(3, 1), "삼일절", weekendRuleFrom3_1 ? .weekendOrOverlap : .none)
        add(fixed(5, 5), "어린이날", childrenWeekend ? .weekendOrOverlap : .none)
        add(solar(ofLunarMonth: 4, day: 8, inYear: year), "부처님오신날", buddhaChristmas ? .weekendOrOverlap : .none)
        add(fixed(6, 6), "현충일", .none)
        add(fixed(8, 15), "광복절", year >= 2021 ? .weekendOrOverlap : .none)
        if let chuseok = solar(ofLunarMonth: 8, day: 15, inYear: year), let cd = cal.date(from: DateComponents(year: chuseok.year, month: chuseok.month, day: chuseok.day, hour: 12)) {
            let rule: SubstituteRule = year >= 2014 ? .sundayOrOverlap : .none
            add(cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: -1, to: cd)!), "추석 연휴", rule)
            add(chuseok, "추석", rule)
            add(cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: 1, to: cd)!), "추석 연휴", rule)
        }
        add(fixed(10, 3), "개천절", year >= 2021 ? .weekendOrOverlap : .none)
        add(fixed(10, 9), "한글날", year >= 2021 ? .weekendOrOverlap : .none)
        add(fixed(12, 25), "성탄절", buddhaChristmas ? .weekendOrOverlap : .none)

        items.sort { $0.date < $1.date }
        let dayKey: (Date) -> Int = { d in
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return c.year! * 10_000 + c.month! * 100 + c.day!
        }
        var taken = Set(items.map { dayKey($0.date) })
        var substitutes: [Item] = []

        // 설·추석: 연휴(3일) 중 일요일이나 다른 공휴일과 겹치는 날 수만큼, 연휴 다음 첫 평일을 쉰다.
        for group in ["설날", "추석"] {
            let days = items.filter { $0.name.hasPrefix(group) && $0.rule == .sundayOrOverlap }
            guard !days.isEmpty else { continue }
            var needed = 0
            for d in days {
                let sunday = cal.component(.weekday, from: d.date) == 1
                let overlap = items.contains { $0.name != d.name && !$0.name.hasPrefix(group) && dayKey($0.date) == dayKey(d.date) }
                if sunday || overlap { needed += 1 }
            }
            var cursor = days.map(\.date).max()!
            while needed > 0 {
                cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
                let weekday = cal.component(.weekday, from: cursor)
                if weekday == 1 || weekday == 7 || taken.contains(dayKey(cursor)) { continue }
                substitutes.append((cursor, "대체공휴일(\(group))", .none))
                taken.insert(dayKey(cursor))
                needed -= 1
            }
        }

        // 그 밖의 날: 토·일요일이나 다른 공휴일과 겹치면 다음 첫 평일.
        for item in items where item.rule == .weekendOrOverlap {
            let weekday = cal.component(.weekday, from: item.date)
            let overlap = items.contains { $0.name != item.name && dayKey($0.date) == dayKey(item.date) }
            guard weekday == 1 || weekday == 7 || overlap else { continue }
            // 설·추석 연휴와 겹친 날은 위에서 연휴 쪽 대체공휴일로 이미 셌다(하루만 준다).
            if items.contains(where: { $0.rule == .sundayOrOverlap && dayKey($0.date) == dayKey(item.date) }) { continue }
            // 겹친 경우, 둘 중 하나만 대체한다(이미 대체를 받은 날이 있으면 건너뜀).
            if overlap, !(weekday == 1 || weekday == 7) {
                let others = items.filter { $0.name != item.name && dayKey($0.date) == dayKey(item.date) }
                if others.contains(where: { o in o.rule == .weekendOrOverlap && o.name < item.name }) { continue }
            }
            var cursor = item.date
            repeat {
                cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
            } while [1, 7].contains(cal.component(.weekday, from: cursor)) || taken.contains(dayKey(cursor))
            substitutes.append((cursor, "대체공휴일(\(item.name))", .none))
            taken.insert(dayKey(cursor))
        }

        return (items.map { ($0, false) } + substitutes.map { ($0, true) })
            .sorted { $0.0.date < $1.0.date }
            .map { pair in
                let c = cal.dateComponents([.year, .month, .day], from: pair.0.date)
                return Holiday(year: c.year!, month: c.month!, day: c.day!, name: pair.0.name, substitute: pair.1)
            }
    }
}
