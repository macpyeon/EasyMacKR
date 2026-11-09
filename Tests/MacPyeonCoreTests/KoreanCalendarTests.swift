import Foundation
import Testing
@testable import MacPyeonCore

struct KoreanCalendarTests {
    private func days(_ year: Int) -> [String] {
        KoreanCalendar.holidays(year: year).map { String(format: "%02d-%02d %@", $0.month, $0.day, $0.name) }
    }

    @Test func lunarHolidays2025() {
        let d = days(2025)
        #expect(d.contains("01-29 설날"))
        #expect(d.contains("01-28 설날 연휴"))
        #expect(d.contains("01-30 설날 연휴"))
        #expect(d.contains("05-05 부처님오신날"))
        #expect(d.contains("10-06 추석"))
    }

    @Test func substitutes2025() {
        let subs = KoreanCalendar.holidays(year: 2025).filter(\.substitute).map { "\($0.month)-\($0.day)" }
        // 삼일절(토) → 3/3, 어린이날·부처님오신날 겹침 → 5/6, 추석 연휴 첫날 일요일 → 10/8
        #expect(subs == ["3-3", "5-6", "10-8"])
    }

    @Test func holidays2026() {
        let d = days(2026)
        #expect(d.contains("02-17 설날"))
        #expect(d.contains("05-24 부처님오신날"))
        #expect(d.contains("09-25 추석"))
        let subs = KoreanCalendar.holidays(year: 2026).filter(\.substitute).map { "\($0.month)-\($0.day)" }
        // 3/1(일)→3/2, 부처님오신날 5/24(일)→5/25, 광복절(토)→8/17, 개천절(토)→10/5
        #expect(subs == ["3-2", "5-25", "8-17", "10-5"])
    }

    /// 추석 연휴(10/2~4)가 개천절(10/3)과 겹치면 대체공휴일은 하루.
    @Test func chuseokOverlappingFoundationDay2028() {
        let subs = KoreanCalendar.holidays(year: 2028).filter(\.substitute).filter { $0.month == 10 }.map(\.day)
        #expect(subs == [5])
    }

    @Test func lunarDateOfToday() {
        let l = KoreanCalendar.lunarDate(year: 2025, month: 10, day: 6)
        #expect(l?.month == 8 && l?.day == 15 && l?.isLeap == false)
        #expect(KoreanCalendar.lunarDate(year: 2026, month: 2, day: 17)?.text == "1.1")
    }
}

struct LeapMonthTests {
    @Test func detectsLeapMonth() {
        // 2025년 윤6월: 양력 7/25 ~ 8/22
        #expect(KoreanCalendar.lunarDate(year: 2025, month: 8, day: 1)?.isLeap == true)
        #expect(KoreanCalendar.lunarDate(year: 2025, month: 8, day: 1)?.text.hasPrefix("윤6.") == true)
    }
}
