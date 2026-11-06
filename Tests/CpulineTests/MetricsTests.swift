import Foundation
import Testing
@testable import Cpuline

struct MetricsTests {
    // MARK: - CoreUsage

    @Test func usageSplitsUserAndSystem() {
        let old = CoreTicks(user: 100, system: 100, idle: 100, nice: 10)
        let new = CoreTicks(user: 120, system: 110, idle: 170, nice: 10)
        let usage = CoreUsage.between(old, new)
        #expect(abs(usage.user - 0.2) < 0.0001)
        #expect(abs(usage.system - 0.1) < 0.0001)
    }

    @Test func usageCountsNiceAsUser() {
        let old = CoreTicks(user: 0, system: 0, idle: 0, nice: 0)
        let new = CoreTicks(user: 0, system: 0, idle: 50, nice: 50)
        #expect(CoreUsage.between(old, new).user == 0.5)
    }

    @Test func usageSurvivesCounterWrap() {
        let old = CoreTicks(user: UInt32.max, system: 0, idle: 0, nice: 0)
        let new = CoreTicks(user: 9, system: 0, idle: 10, nice: 0)
        #expect(CoreUsage.between(old, new).user == 0.5)
    }

    @Test func usageIsZeroWithoutElapsedTicks() {
        let ticks = CoreTicks(user: 5, system: 5, idle: 5, nice: 5)
        #expect(CoreUsage.between(ticks, ticks).total == 0)
    }

    // MARK: - CoreGroup

    @Test func groupsFollowPerformanceLevels() {
        let groups = CoreGroup.make(levels: [("Efficiency", 6), ("Performance", 4)], total: 10)
        #expect(groups == [CoreGroup(name: "Efficiency", cores: 0..<6), CoreGroup(name: "Performance", cores: 6..<10)])
    }

    @Test func groupsFallBackToAllCores() {
        #expect(CoreGroup.make(levels: [], total: 8) == [CoreGroup(name: "All", cores: 0..<8)])
        #expect(CoreGroup.make(levels: [("Efficiency", 2)], total: 8) == [CoreGroup(name: "All", cores: 0..<8)])
    }

    // MARK: - ProcessParser

    @Test func creditsHelpersToTheirApp() {
        let owner = ProcessParser.owner(of: "/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper")
        #expect(owner.name == "Foo")
        #expect(owner.iconPath == "/Applications/Foo.app")
    }

    @Test func groupsSystemBinariesAsMacOS() {
        #expect(ProcessParser.owner(of: "/usr/libexec/opendirectoryd").name == "macOS")
        #expect(ProcessParser.owner(of: "kernel_task").name == "macOS")
    }

    @Test func keepsOtherExecutablesByName() {
        #expect(ProcessParser.owner(of: "/opt/homebrew/bin/node").name == "node")
        #expect(ProcessParser.owner(of: "claude").iconPath == nil)
    }

    @Test func topSumsOwnersAndScalesToAllCores() {
        let output = """
         20.0 /Applications/Foo.app/Contents/MacOS/Foo
         20.0 /Applications/Foo.app/Contents/MacOS/Foo Helper
         30,0 /usr/sbin/cfprefsd
         10.0 node
        garbage
        """
        let top = ProcessParser.top(psOutput: output, coreCount: 10, limit: 2)
        #expect(top.map(\.name) == ["Foo", "macOS"])
        #expect(top.map(\.percent) == [4, 3])
    }

    // MARK: - Format

    @Test func uptimeUsesLargestUnit() {
        #expect(Format.uptime(seconds: 9 * 86_400 + 3_600) == "9 days")
        #expect(Format.uptime(seconds: 86_400) == "1 day")
        #expect(Format.uptime(seconds: 2 * 3_600 + 60) == "2 hours")
        #expect(Format.uptime(seconds: 60) == "1 minute")
    }

    // MARK: - GPUClock

    @Test func parsesHzAndKHzTables() {
        // (0, v), (1_578_000_000, v) in Hz
        let hz = Data([0, 0, 0, 0, 0x7d, 0, 0, 0, 0x80, 0x5e, 0x0e, 0x5e, 0x0b, 0x04, 0, 0])
        #expect(GPUClock.parseFrequenciesHz(hz) == [0, 1_578_000_000])
        // (396_000, v) in kHz
        let kHz = Data([0xe0, 0x0a, 0x06, 0, 0x7d, 0, 0, 0])
        #expect(GPUClock.parseFrequenciesHz(kHz) == [396_000_000])
    }

    @Test func averageClockCountsOffTimeAsZero() {
        #expect(GPUClock.averageGHz(residencies: [1, 1], frequenciesHz: [0, 1_000_000_000]) == 0.5)
    }

    @Test func averageClockNeedsMatchingData() {
        #expect(GPUClock.averageGHz(residencies: [0, 0], frequenciesHz: [0, 1]) == nil)
        #expect(GPUClock.averageGHz(residencies: [1], frequenciesHz: [0, 1]) == nil)
    }
}
