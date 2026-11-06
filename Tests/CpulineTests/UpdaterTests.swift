import Foundation
import Testing
@testable import Cpuline

struct UpdaterTests {
    private func json(tag: String, asset: String = "Cpuline.zip", url: String? = nil) -> Data {
        let link = url ?? "https://github.com/aca2328/Cpuline/releases/download/\(tag)/\(asset)"
        return Data("""
        {"tag_name":"\(tag)","draft":false,"assets":[{"name":"\(asset)","browser_download_url":"\(link)"}]}
        """.utf8)
    }

    @Test func parsesCurrentRelease() {
        let release = Updater.parseRelease(json(tag: "v1.0.100"))
        #expect(release?.build == 100)
        #expect(release?.version == "v1.0.100")
    }

    @Test func rejectsReleaseWithOtherAssetName() {
        #expect(Updater.parseRelease(json(tag: "v1.0.30", asset: "Other.zip")) == nil)
    }

    @Test func rejectsMalformedTags() {
        #expect(Updater.parseRelease(json(tag: "v2.0.5")) == nil)
        #expect(Updater.parseRelease(json(tag: "v1.0.abc")) == nil)
    }

    @Test func rejectsDownloadsFromElsewhere() {
        #expect(Updater.parseRelease(json(tag: "v1.0.100", url: "https://example.com/Cpuline.zip")) == nil)
        #expect(Updater.parseRelease(json(tag: "v1.0.100", url: "https://github.com/someone/Cpuline/releases/download/v1.0.100/Cpuline.zip")) == nil)
    }

    @Test func rejectsInvalidJSON() {
        #expect(Updater.parseRelease(Data("not json".utf8)) == nil)
    }
}

struct LoginItemTests {
    @Test func offersOnlyFromApplicationsFolders() {
        let home = "/Users/me"
        func installed(_ path: String) -> Bool {
            LoginItem.isInstalled(URL(fileURLWithPath: path), home: home)
        }
        #expect(installed("/Applications/Cpuline.app"))
        #expect(installed("/Users/me/Applications/Cpuline.app"))
        #expect(!installed("/Users/me/GitHub/Cpuline/.build/Cpuline.app"))
        #expect(!installed("/Applications/Cpuline"))
    }
}
