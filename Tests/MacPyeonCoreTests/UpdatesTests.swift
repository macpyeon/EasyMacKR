import Foundation
import Testing
@testable import MacPyeonCore

struct UpdatesTests {
    @Test func parsesVersions() {
        #expect(AppVersion("v0.1.2")?.parts == [0, 1, 2])
        #expect(AppVersion("1.0")?.parts == [1, 0])
        #expect(AppVersion("0.2.0-beta.1")?.parts == [0, 2, 0])
        #expect(AppVersion("") == nil)
        #expect(AppVersion("abc") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    @Test func comparesNumericallyNotAsText() {
        let a = AppVersion("0.1.9")!, b = AppVersion("0.1.10")!
        #expect(a < b)
        #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
        #expect(!(AppVersion("0.2")! < AppVersion("0.1.5")!))
    }

    @Test func notifiesOnlyForNewerUnskipped() {
        let cur = AppVersion("0.1.1")!
        #expect(UpdatePolicy.shouldNotify(current: cur, latest: AppVersion("0.1.2")!, skipped: nil))
        #expect(!UpdatePolicy.shouldNotify(current: cur, latest: AppVersion("0.1.1")!, skipped: nil))
        #expect(!UpdatePolicy.shouldNotify(current: cur, latest: AppVersion("0.1.0")!, skipped: nil))
        #expect(!UpdatePolicy.shouldNotify(current: cur, latest: AppVersion("0.1.2")!, skipped: AppVersion("0.1.2")))
        #expect(UpdatePolicy.shouldNotify(current: cur, latest: AppVersion("0.1.3")!, skipped: AppVersion("0.1.2")))
    }

    @Test func koreanParticles() {
        #expect(AppVersion("0.1.1")!.withSubject == "0.1.1이")
        #expect(AppVersion("0.1.2")!.withSubject == "0.1.2가")
        #expect(AppVersion("0.1.10")!.withSubject == "0.1.10이")
        #expect(AppVersion("0.1.0")!.withDirection == "0.1.0으로")
        #expect(AppVersion("0.1.1")!.withDirection == "0.1.1로")
        #expect(AppVersion("0.1.9")!.withDirection == "0.1.9로")
        #expect(AppVersion("0.1.6")!.withDirection == "0.1.6으로")
    }

    @Test func parsesGitHubRelease() {
        let json = """
        {"tag_name":"v0.1.2","html_url":"https://github.com/macpyeon/EasyMacKR/releases/tag/v0.1.2",
         "draft":false,"prerelease":false,"body":"- 첫째\\r\\n- 둘째\\r\\n\\r\\n업데이트: brew"}
        """.data(using: .utf8)!
        let r = ReleaseInfo.parse(json: json)
        #expect(r?.version == AppVersion("0.1.2"))
        #expect(r?.summaryLines() == ["첫째", "둘째"])
    }

    @Test func ignoresPrereleaseAndBadURL() {
        let pre = #"{"tag_name":"v9.0.0","html_url":"https://x.y/z","prerelease":true}"#.data(using: .utf8)!
        #expect(ReleaseInfo.parse(json: pre) == nil)
        let http = #"{"tag_name":"v9.0.0","html_url":"http://x.y/z"}"#.data(using: .utf8)!
        #expect(ReleaseInfo.parse(json: http) == nil)
        #expect(ReleaseInfo.parse(json: Data("nope".utf8)) == nil)
    }
}
