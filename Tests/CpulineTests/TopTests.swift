import AppKit
import Testing
@testable import Cpuline

struct TopTests {
    // Real rows captured from `top -l 0 -stats` with `TopColumn.streamKeys`.
    private let windowServer = "620    22.1 12:35:39 21     6650-  802M   301M   1     sleeping 18563242+  _windowserver         479369559 379673635 209281883+ 26725781+ 26299   WindowServer    "
    private let kernel = "0      10.5 13:15:24 722/10 0      27M-   0B     0     running  203185790+ root                  52045669  57389271  2147483647 981145+   0       kernel_task     "
    private let helper = "52304  0.0  42:24.75 16     101    21M    16M    52188 sleeping 5824       aca2328               0         0         1000       2000      30      Claude Helper (P"

    private func process(_ line: String) -> TopProcess {
        TopProcess(line: line)!
    }

    private func counters(switches: Double, faults: Double, pageins: Double) -> TopProcess.Counters {
        .init(instructions: 0, cycles: 0, switches: switches, faults: faults, pageins: pageins)
    }

    private func stream(rows: [String]) -> Data {
        Data(("Processes: \(rows.count) total, 1 running\nLoad Avg: 1.96, 2.21, 2.42 \n\n"
            + "PID    %CPU TIME\n" + rows.joined(separator: "\n") + "\n").utf8)
    }

    // MARK: - Rows

    @Test func readsFieldsAndStripsChangeMarkers() {
        let row = process(windowServer)
        #expect(row.pid == 620)
        #expect(row[.cpu] == "22.1")
        #expect(row[.ports] == "6650")
        #expect(row[.idleWakeups] == "18563242")
        #expect(row[.user] == "_windowserver")
        #expect(row[.command] == "WindowServer")
    }

    @Test func keepsSpacesInCommands() {
        #expect(process(helper)[.command] == "Claude Helper (P")
    }

    @Test func rejectsLinesThatAreNotRows() {
        #expect(TopProcess(line: "") == nil)
        #expect(TopProcess(line: "VM: 449T vsize, 57G framework vsize, 258145(0) swapins, 676811(0) swapouts, x, y, z, a, b") == nil)
    }

    // MARK: - Sort values

    @Test func convertsUnitsTimesAndThreads() {
        #expect(TopColumn.memory.sortValue("1195M") == 1195 * 1_048_576)
        #expect(TopColumn.memory.sortValue("8016K") == 8016 * 1_024)
        #expect(TopColumn.memory.sortValue("0B") == 0)
        #expect(TopColumn.time.sortValue("13:15:24") == 47_724)
        #expect(TopColumn.time.sortValue("42:24.75") == 2_544.75)
        #expect(TopColumn.threads.sortValue("722/10") == 722)
        #expect(TopColumn.cpu.sortValue("3,2") == 3.2)
    }

    @MainActor @Test func sortsNumbersByValueNotText() {
        let rows = [process(windowServer), process(kernel), process(helper)]
        let byMemory = ProcessTableController.sorted(rows, by: NSSortDescriptor(key: String(TopColumn.memory.rawValue), ascending: false))
        #expect(byMemory.map(\.pid) == [620, 0, 52304])
        let byName = ProcessTableController.sorted(rows, by: NSSortDescriptor(key: String(TopColumn.command.rawValue), ascending: true))
        #expect(byName.map(\.pid) == [52304, 0, 620])
    }

    // MARK: - Full names

    @Test func restoresTruncatedNames() {
        var row = process(helper)
        row.restoreFullName(path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Plugin)")
        #expect(row[.command] == "Claude Helper (Plugin)")
    }

    @Test func keepsNameWhenPathIsSomethingElse() {
        var row = process(helper)
        row.restoreFullName(path: "/usr/bin/other")
        #expect(row[.command] == "Claude Helper (P")
        var short = process(kernel)
        short.restoreFullName(path: "/x/kernel_task_long")
        #expect(short[.command] == "kernel_task")
    }

    // MARK: - Worked-out columns

    @Test func ipcIsInstructionsOverCycles() {
        #expect(process(windowServer)[.ipc] == "1.26")
        #expect(process(windowServer).sortValues[TopColumn.ipc.rawValue] == 1.26)
        #expect(process(helper)[.ipc] == "")
    }

    @Test func ratesUseElapsedSeconds() {
        var row = process(helper)
        row.setRates(since: counters(switches: 600, faults: 1_000, pageins: 30), seconds: 2)
        #expect(row[.switchRate] == "200")
        #expect(row[.faultRate] == "500")
        #expect(row[.pageinRate] == "0")
    }

    @Test func ratesStayBlankWithoutAComparison() {
        var row = process(helper)
        row.setRates(since: nil, seconds: 2)
        #expect(row[.switchRate] == "")
        // A lower total means the PID now belongs to another process.
        row.setRates(since: counters(switches: 5_000, faults: 0, pageins: 0), seconds: 2)
        #expect(row[.switchRate] == "")
        #expect(row[.faultRate] == "1000")
    }

    @Test func saturatedCounterHasNoRate() {
        var row = process(kernel)
        row.setRates(since: row.counters, seconds: 2)
        #expect(row[.switchRate] == "")
        #expect(row[.faultRate] == "0")
    }

    // MARK: - Graph totals

    @Test func totalsSumTheListsColumns() {
        var a = process(windowServer)
        var b = process(helper)
        a.setRates(since: counters(switches: 209_281_683, faults: 26_725_781, pageins: 26_299), seconds: 2)
        b.setRates(since: counters(switches: 900, faults: 1_000, pageins: 10), seconds: 2)
        let rows = [a, b]
        #expect(ListMetric.cpu.value(in: rows) == 22.1)
        #expect(ListMetric.memory.value(in: rows) == (802.0 + 21.0) / 1_024)
        #expect(ListMetric.switches.value(in: rows) == 150)
        #expect(ListMetric.faults.value(in: rows) == 500)
        #expect(ListMetric.pageins.value(in: rows) == 10)
    }

    @Test func totalIPCWeighsByCycles() throws {
        // 479369559 / 379673635 and 52045669 / 57389271, weighted; not their mean.
        let ipc = try #require(ListMetric.ipc.value(in: [process(windowServer), process(kernel)]))
        #expect(abs(ipc - 531_415_228 / 437_062_906) < 0.0001)
        #expect(ListMetric.ipc.value(in: [process(helper)]) == nil)
    }

    @Test func scalesToRoundCeilingsAboveAMinimum() {
        #expect(ListMetric.cpu.ceiling(forPeak: 40) == 100)
        #expect(ListMetric.cpu.ceiling(forPeak: 120) == 200)
        #expect(ListMetric.cpu.ceiling(forPeak: 200) == 200)
        #expect(ListMetric.faults.ceiling(forPeak: 13_604) == 20_000)
        #expect(ListMetric.pageins.ceiling(forPeak: 0) == 10)
        #expect(ListMetric.memory.ceiling(forPeak: 37) == 50)
        #expect(ListMetric.switches.ceiling(forPeak: 21_000) == 30_000)
    }

    @Test func formatsValuesCompactly() {
        #expect(ListMetric.cpu.format(123.4) == "123%")
        #expect(ListMetric.ipc.format(1.234) == "1.23")
        #expect(ListMetric.memory.format(12.34) == "12.3G")
        #expect(ListMetric.faults.format(999) == "999")
        #expect(ListMetric.faults.format(13_604) == "13.6K")
        #expect(ListMetric.switches.format(2_500_000) == "2.5M")
    }

    // MARK: - Categories

    @Test func categorizesByExecutablePath() {
        let cases: [(String, ProcessCategory)] = [
            ("/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper", .apps),
            ("/System/Applications/Mail.app/Contents/MacOS/Mail", .apps),
            ("/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtect", .macOS),
            ("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", .macOS),
            ("/usr/libexec/trustd", .macOS),
            ("/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine", .virtualMachines),
            ("/Library/SystemExtensions/x/io.tailscale.ipn.macsys.network-extension", .services),
            ("/bin/zsh", .commandLine),
            ("/opt/homebrew/bin/node", .commandLine)
        ]
        for (path, category) in cases {
            #expect(ProcessCategory(path: path, pid: 5) == category, "\(path)")
        }
    }

    @Test func aProcessWithoutAPathIsOtherUnlessItsTheKernel() {
        #expect(ProcessCategory(path: nil, pid: 0) == .macOS)
        #expect(ProcessCategory(path: nil, pid: 5) == .other)
    }

    private func categorized(_ line: String, _ path: String) -> TopProcess {
        var row = process(line)
        row.setCategory(path: path)
        return row
    }

    @MainActor @Test func groupsFollowTheSortAndContainSortedRows() {
        let rows = [categorized(helper, "/Applications/C.app/Contents/MacOS/C"),
                    categorized(windowServer, "/System/Library/WindowServer"),
                    categorized(kernel, "/System/kernel")]
        let groups = ProcessTableController.grouped(rows, by: NSSortDescriptor(key: String(TopColumn.cpu.rawValue), ascending: false))
        #expect(groups.map(\.category) == [.macOS, .apps])
        #expect(groups[0].rows.map(\.pid) == [620, 0])
        let byName = ProcessTableController.grouped(rows, by: NSSortDescriptor(key: String(TopColumn.category.rawValue), ascending: true))
        #expect(byName.map(\.category) == [.apps, .macOS])
        // PID has no total, so categories keep their usual order.
        let byPID = ProcessTableController.grouped(rows, by: NSSortDescriptor(key: String(TopColumn.pid.rawValue), ascending: false))
        #expect(byPID.map(\.category) == [.apps, .macOS])
    }

    @Test func totalsAreWrittenLikeTheirColumns() {
        let rows = [process(windowServer), process(helper)]
        #expect(TopColumn.cpu.totalText(of: rows) == "22.1")
        #expect(TopColumn.memory.totalText(of: rows) == "823M")
        #expect(TopColumn.threads.totalText(of: rows) == "37")
        #expect(TopColumn.memory.totalText(of: rows + rows) == "1.6G")
        #expect(TopColumn.pid.totalText(of: rows) == "")
    }

    // MARK: - Heat

    private let sixteenGB = 16.0 * 1_073_741_824

    @Test func heatFollowsWhicheverResourceIsHigher() {
        // WindowServer: 22.1% of a core, against 802M of a 4 GB quarter (19.6%).
        #expect(Heat.score(of: process(windowServer), physicalMemory: sixteenGB) == 0.221)
        var busy = process(helper)
        busy.set(.cpu, "150.0")
        #expect(Heat.score(of: busy, physicalMemory: sixteenGB) == 1)
        var big = process(helper)
        big.set(.memory, "2G")
        #expect(Heat.score(of: big, physicalMemory: sixteenGB) == 0.5)
    }

    @Test func categoryHeatIsAgainstTheWholeMac() {
        // 22.1% of 10 cores, against 802M of 16 GB (4.9%).
        let score = Heat.score(of: [process(windowServer)], coreCount: 10, physicalMemory: sixteenGB)
        #expect(abs(score - 0.0490) < 0.001)
        var busy = process(helper)
        busy.set(.cpu, "500.0")
        #expect(Heat.score(of: [busy, busy], coreCount: 10, physicalMemory: sixteenGB) == 1)
    }

    @Test func colorGoesFromGreenThroughYellowToRed() {
        let (cool, warm, hot) = (Heat.rgb(0), Heat.rgb(0.5), Heat.rgb(1))
        #expect(cool.green == 1 && cool.red < 0.5)
        #expect(warm.red == 1 && warm.green > 0.8)
        #expect(hot.red == 1 && hot.green < 0.3)
        #expect(Heat.rgb(0.25).red < Heat.rgb(0.75).red)
        #expect(Heat.background(0).alphaComponent == 0)
        #expect(Heat.groupBackground(0).alphaComponent > 0)
    }

    // MARK: - Resource reports

    private let cpuReport = """
    Date/Time:        2026-11-07 02:51:40.662 +0100
    End time:         2026-11-07 02:53:42.644 +0100
    Command:          spotlightknowledged
    Event:            cpu usage
    Action taken:     none
    """

    @Test func readsAReportHeader() throws {
        let report = try #require(ResourceReports.parse(cpuReport))
        #expect(report.command == "spotlightknowledged")
        #expect(report.kind == "CPU")
        #expect(report.date == Date(timeIntervalSince1970: 1_794_016_300.662))
    }

    @Test func ignoresOtherReports() {
        #expect(ResourceReports.parse(#"{"timestamp":"2026-11-07 03:01:13.40 +0100","bug_type":"226"}"#) == nil)
        #expect(ResourceReports.parse(cpuReport.replacingOccurrences(of: "cpu usage", with: "hang")) == nil)
    }

    @Test func marksRecentReportsByProgram() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day = 86_400.0
        let marks = ResourceReports.marks([
            .init(command: "a", kind: "Disk", date: now.addingTimeInterval(-day)),
            .init(command: "a", kind: "CPU", date: now.addingTimeInterval(-6 * day)),
            .init(command: "a", kind: "CPU", date: now),
            .init(command: "old", kind: "CPU", date: now.addingTimeInterval(-8 * day))
        ], now: now)
        #expect(marks == ["a": "CPU Disk"])
    }

    @MainActor @Test func markedProgramsSortFirst() {
        var marked = process(helper)
        marked.set(.limits, "CPU Disk")
        let rows = [process(windowServer), marked]
        let sorted = ProcessTableController.sorted(rows, by: NSSortDescriptor(key: String(TopColumn.limits.rawValue), ascending: false))
        #expect(sorted.map(\.pid) == [52304, 620])
    }

    // MARK: - Stream

    @Test func ratesCarryAcrossSamples() {
        let parser = TopStreamParser()
        let start = Date(timeIntervalSince1970: 0)
        _ = parser.feed(stream(rows: [helper]), now: start)
        let later = helper.replacingOccurrences(of: "1000       2000", with: "1100       2000")
        let samples = parser.feed(stream(rows: [later]), now: start.addingTimeInterval(2))
        #expect(samples.map { $0.processes[0][.switchRate] } == ["50"])
    }

    @Test func dropsFirstSampleThenClosesTableOnRowCount() {
        let parser = TopStreamParser()
        #expect(parser.feed(stream(rows: [windowServer, kernel])).isEmpty)
        let samples = parser.feed(stream(rows: [windowServer, kernel]))
        #expect(samples.count == 1)
        #expect(samples[0].processes.map(\.pid) == [620, 0])
        #expect(samples[0].summary[0] == "Processes: 2 total, 1 running")
    }

    @Test func handlesDataSplitMidLine() {
        let parser = TopStreamParser()
        _ = parser.feed(stream(rows: [kernel]))
        let data = stream(rows: [kernel])
        let middle = data.count / 2
        #expect(parser.feed(data[data.startIndex..<(data.startIndex + middle)]).isEmpty)
        #expect(parser.feed(data[(data.startIndex + middle)...]).count == 1)
    }

    @Test func nextHeaderClosesATableWithTooFewRows() {
        let parser = TopStreamParser()
        _ = parser.feed(stream(rows: [kernel]))
        // Announces two rows but delivers one.
        let short = "Processes: 2 total\n\nPID    %CPU\n\(kernel)\n"
        #expect(parser.feed(Data(short.utf8)).isEmpty)
        #expect(parser.feed(Data("Processes: 1 total\n".utf8)).map(\.processes.count) == [1])
    }
}
