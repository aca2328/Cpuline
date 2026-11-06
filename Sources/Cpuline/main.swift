@preconcurrency import Darwin
import AppKit
import IOKit
import ServiceManagement
import Foundation

enum CommandResult {
    case success(String)
    case failure(String)
}

final class CommandRunner {
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        let lock = NSLock()
        var didTimeout = false
        let timeoutWork = DispatchWorkItem {
            lock.lock()
            didTimeout = true
            lock.unlock()
            if process.isRunning {
                process.terminate()
            }
        }

        do {
            try process.run()
        } catch {
            return .failure("cannot run \(launchPath): \(error.localizedDescription)")
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        // Read before waiting: output larger than the pipe buffer (64 KB, which
        // ps can reach) would otherwise block the child forever.
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()

        lock.lock()
        let timedOut = didTimeout
        lock.unlock()

        if timedOut {
            return .failure("timeout")
        }

        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            return .failure(err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "exit \(process.terminationStatus)" : err)
        }

        return .success(out)
    }
}


/// Offers to add the app to Login Items, once. Only from an Applications folder:
/// a login item pointing at a build folder would break on the next rebuild.
enum LoginItem {
    private static let askedKey = "didOfferLoginItem"

    static func isInstalled(_ bundleURL: URL, home: String = NSHomeDirectory()) -> Bool {
        bundleURL.pathExtension == "app"
            && (bundleURL.path.hasPrefix("/Applications/") || bundleURL.path.hasPrefix(home + "/Applications/"))
    }

    @MainActor static func offerIfNeeded() {
        guard isInstalled(Bundle.main.bundleURL),
              // Not `== .notRegistered`: ad-hoc signed bundles can report .notFound until registered.
              ![.enabled, .requiresApproval].contains(SMAppService.mainApp.status),
              !UserDefaults.standard.bool(forKey: askedKey) else { return }
        UserDefaults.standard.set(true, forKey: askedKey)

        let alert = NSAlert()
        alert.messageText = "Open Cpuline at login?"
        alert.informativeText = "Cpuline will start in the menu bar when you log in. You can change this later in System Settings › General › Login Items."
        alert.addButton(withTitle: "Open at Login")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Finds and installs new GitHub releases. Relies on release.sh's tag format
/// (`v1.0.<build>`) and asset name (`Cpuline.zip`).
enum Updater {
    struct Release: Equatable, Sendable {
        let build: Int
        let downloadURL: String
        var version: String { "v1.0.\(build)" }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let releasePageURL = URL(string: "https://github.com/aca2328/Cpuline/releases/latest")!
    private static let apiURL = "https://api.github.com/repos/aca2328/Cpuline/releases/latest"
    private static let appName = "Cpuline.app"

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let assets: [Asset]
    }

    /// The release described by the GitHub API response, or nil unless it has
    /// a well-formed tag and a `Cpuline.zip` hosted in this repo's releases.
    static func parseRelease(_ data: Data) -> Release? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.tag_name.hasPrefix("v1.0."),
              let build = Int(payload.tag_name.dropFirst("v1.0.".count)), build > 0,
              let asset = payload.assets.first(where: { $0.name == "Cpuline.zip" }),
              asset.browser_download_url == "https://github.com/aca2328/Cpuline/releases/download/\(payload.tag_name)/Cpuline.zip" else {
            return nil
        }
        return Release(build: build, downloadURL: asset.browser_download_url)
    }

    static func fetchLatest() throws -> Release? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try curl(apiURL, to: file, timeout: 15)
        return parseRelease(try Data(contentsOf: file))
    }

    /// Replacing the app needs a real, writable bundle: not `swift run`, and
    /// not a read-only translocated copy that macOS is running from quarantine.
    static func canInstall(over bundleURL: URL) -> Bool {
        bundleURL.pathExtension == "app"
            && !bundleURL.path.contains("/AppTranslocation/")
            && FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
    }

    /// Downloads and verifies the release, then swaps it in once `pid` exits.
    /// Throws without touching the current app if any step before the swap fails.
    static func install(_ release: Release, over bundleURL: URL, pid: Int32) throws {
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: bundleURL, create: true)
        do {
            let zip = staging.appendingPathComponent("Cpuline.zip")
            try curl(release.downloadURL, to: zip, timeout: 300)
            let app = try unpackAndVerify(zip: zip, into: staging, build: release.build)
            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/sh")
            swap.arguments = ["-c", swapScript, "sh", String(pid), bundleURL.path, app.path, staging.path]
            swap.standardInput = FileHandle.nullDevice
            swap.standardOutput = FileHandle.nullDevice
            swap.standardError = FileHandle.nullDevice
            try swap.run()
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Extracts the zip and returns its app, if that app is this app at exactly
    /// `build` and its signature is intact.
    static func unpackAndVerify(zip: URL, into directory: URL, build: Int) throws -> URL {
        let extracted = directory.appendingPathComponent("extracted")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path], timeout: 60)
        let app = extracted.appendingPathComponent(appName)
        guard let info = Bundle(url: app)?.infoDictionary else {
            throw Failure(message: "The download doesn't contain \(appName).")
        }
        guard info["CFBundleIdentifier"] as? String == "org.camerlo.Cpuline" else {
            throw Failure(message: "The download is a different app.")
        }
        guard info["CFBundleVersion"] as? String == String(build) else {
            throw Failure(message: "The download's version doesn't match the release.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 60)
        return app
    }

    /// Run detached so it outlives the app. Arguments: pid, current app, new
    /// app, staging folder. Puts the current app back if the new one won't move
    /// in, and always reopens whichever app is left in place.
    static let swapScript = """
    export PATH=/usr/bin:/bin
    pid="$1"; current="$2"; new="$3"; staging="$4"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    if ! mv "$current" "$staging/previous.app"; then
        open "$current"
        exit 1
    fi
    if mv "$new" "$current"; then
        xattr -dr com.apple.quarantine "$current" 2>/dev/null
        rm -rf "$staging"
    else
        mv "$staging/previous.app" "$current"
    fi
    open "$current"
    """

    private static func curl(_ url: String, to file: URL, timeout: TimeInterval) throws {
        try run("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--location",
                                  "--max-time", String(Int(timeout)), "--output", file.path, url],
                timeout: timeout + 5)
    }

    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) throws {
        if case let .failure(message) = CommandRunner.run(path, arguments, timeout: timeout) {
            throw Failure(message: message)
        }
    }
}

/// One logical CPU's cumulative tick counters, from `host_processor_info`.
struct CoreTicks: Equatable, Sendable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
}

/// Share of a core's time (0...1) spent in user and system code.
struct CoreUsage: Equatable, Sendable {
    var user = 0.0
    var system = 0.0
    var total: Double { user + system }

    static func between(_ old: CoreTicks, _ new: CoreTicks) -> CoreUsage {
        // The counters are 32-bit and wrap; &- keeps the delta right across a wrap.
        let user = Double(new.user &- old.user) + Double(new.nice &- old.nice)
        let system = Double(new.system &- old.system)
        let all = user + system + Double(new.idle &- old.idle)
        guard all > 0 else { return CoreUsage() }
        return CoreUsage(user: user / all, system: system / all)
    }

    static func average(_ cores: ArraySlice<CoreUsage>) -> CoreUsage {
        guard !cores.isEmpty else { return CoreUsage() }
        let count = Double(cores.count)
        return CoreUsage(user: cores.map(\.user).reduce(0, +) / count,
                         system: cores.map(\.system).reduce(0, +) / count)
    }
}

/// A run of cores of one kind, e.g. "Efficiency" = logical CPUs 0..<6.
struct CoreGroup: Equatable, Sendable {
    let name: String
    let cores: Range<Int>

    /// `levels` is ordered as the kernel numbers CPUs: slowest cores first.
    /// Macs without performance levels (Intel) get one group of every core.
    static func make(levels: [(name: String, count: Int)], total: Int) -> [CoreGroup] {
        guard !levels.isEmpty, levels.map(\.count).reduce(0, +) == total else {
            return [CoreGroup(name: "All", cores: 0..<total)]
        }
        var start = 0
        return levels.map { level in
            defer { start += level.count }
            return CoreGroup(name: level.name, cores: start..<(start + level.count))
        }
    }
}

/// CPU use by one app, or by the system as a whole. `percent` is of all cores.
struct ProcessUsage: Equatable, Sendable {
    let name: String
    let percent: Double
    let iconPath: String?
}

enum ProcessParser {
    static let systemName = "macOS"

    /// Who to credit for an executable: the outermost app bundle containing it
    /// (so helpers count toward their app), "macOS" for OS binaries, otherwise
    /// the executable itself.
    static func owner(of command: String) -> (name: String, iconPath: String?) {
        if let range = command.range(of: ".app/") {
            let appPath = String(command[..<range.lowerBound]) + ".app"
            let name = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            return (name, appPath)
        }
        let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]
        if command == "kernel_task" || systemPrefixes.contains(where: command.hasPrefix) {
            return (systemName, nil)
        }
        return (URL(fileURLWithPath: command).lastPathComponent, command.hasPrefix("/") ? command : nil)
    }

    /// The busiest owners in `ps -Ao pcpu=,comm=` output. ps reports percent of
    /// one core; dividing by `coreCount` puts it on the same scale as User/System.
    static func top(psOutput: String, coreCount: Int, limit: Int) -> [ProcessUsage] {
        var totals: [String: (percent: Double, iconPath: String?)] = [:]
        for line in psOutput.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            // ps follows the locale, so a French system prints "3,2".
            guard parts.count == 2,
                  let percent = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else { continue }
            let owner = owner(of: String(parts[1]).trimmingCharacters(in: .whitespaces))
            totals[owner.name, default: (0, owner.iconPath)].percent += percent
        }
        return totals
            .map { ProcessUsage(name: $0.key, percent: $0.value.percent / Double(max(coreCount, 1)), iconPath: $0.value.iconPath) }
            .sorted { ($0.percent, $1.name) > ($1.percent, $0.name) }
            .prefix(limit)
            .map { $0 }
    }
}

enum Format {
    static func uptime(seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        func unit(_ value: Int, _ name: String) -> String { "\(value) \(name)\(value == 1 ? "" : "s")" }
        if minutes >= 24 * 60 { return unit(minutes / (24 * 60), "day") }
        if minutes >= 60 { return unit(minutes / 60, "hour") }
        return unit(minutes, "minute")
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    static func load(_ load: [Double]) -> String {
        load.map { String(format: "%.2f", locale: .current, $0) }.joined(separator: " ")
    }
}

enum GPUClock {
    /// Frequencies from a pmgr `voltage-states` property: little-endian UInt32
    /// (frequency, voltage) pairs. Apple silicon generations differ in whether
    /// frequencies are in Hz or kHz, so the size of the top value decides.
    static func parseFrequenciesHz(_ data: Data) -> [Double] {
        let bytes = [UInt8](data)
        let values = stride(from: 0, to: bytes.count - bytes.count % 8, by: 8).map { offset in
            (0..<4).reduce(0.0) { $0 + Double(bytes[offset + $1]) * pow(256, Double($1)) }
        }
        let scale = (values.max() ?? 0) > 1e8 ? 1.0 : 1000.0
        return values.map { $0 * scale }
    }

    /// Average clock over the interval, in GHz, counting time powered off as
    /// 0 GHz. Nil if there's no residency, or it doesn't line up with the table.
    static func averageGHz(residencies: [Int64], frequenciesHz: [Double]) -> Double? {
        let total = residencies.reduce(0, +)
        guard total > 0, residencies.count == frequenciesHz.count else { return nil }
        let weighted = zip(residencies, frequenciesHz).reduce(0.0) { $0 + Double($1.0) * $1.1 }
        return weighted / Double(total) / 1e9
    }
}

/// Everything shown at one instant. `detail` is only sampled while the popover is open.
struct Snapshot: Sendable {
    struct Detail: Sendable {
        var processes: [ProcessUsage] = []
        var temperature: Double?
        var gigahertz: Double?
        var maxGigahertz: Double?
    }

    let time: TimeInterval
    let cores: [CoreUsage]
    let gpuUtilization: Double?
    let gpuMemory: Double?
    let load: [Double]
    let uptime: TimeInterval
    let detail: Detail?

    var cpu: CoreUsage { CoreUsage.average(cores[...]) }
}

func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
}

/// Reads the GPU's clock residency through the private libIOReport, looked up
/// at runtime so a missing library or channel just leaves the value empty.
final class GPUClockReader {
    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    private typealias CreateSamples = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelName = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private struct API {
        let createSamples: CreateSamples
        let createDelta: CreateDelta
        let channelName: ChannelName
        let stateCount: StateCount
        let stateResidency: StateResidency
        let subscription: CFTypeRef
        let channels: CFMutableDictionary
    }

    private let api: API?
    private let frequenciesHz: [Double]
    private var previous: CFDictionary?
    private var previousTime: TimeInterval = -.infinity
    private static let maxSampleGap: TimeInterval = 2.5

    var maxGHz: Double? { frequenciesHz.max().map { $0 / 1e9 } }

    init() {
        frequenciesHz = Self.readFrequencyTable()
        api = Self.connect()
    }

    private static func readFrequencyTable() -> [Double] {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard entry != 0 else { return [] }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "voltage-states9" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return [] }
        return GPUClock.parseFrequenciesHz(data)
    }

    private static func connect() -> API? {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copyChannels = symbol("IOReportCopyChannelsInGroup", as: CopyChannels.self),
              let createSubscription = symbol("IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = symbol("IOReportCreateSamples", as: CreateSamples.self),
              let createDelta = symbol("IOReportCreateSamplesDelta", as: CreateDelta.self),
              let channelName = symbol("IOReportChannelGetChannelName", as: ChannelName.self),
              let stateCount = symbol("IOReportStateGetCount", as: StateCount.self),
              let stateResidency = symbol("IOReportStateGetResidency", as: StateResidency.self),
              let wanted = copyChannels("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)?.takeRetainedValue()
        else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, wanted, &subscribed, 0, nil)?.takeRetainedValue(),
              let channels = subscribed?.takeRetainedValue() else { return nil }
        return API(createSamples: createSamples, createDelta: createDelta, channelName: channelName,
                   stateCount: stateCount, stateResidency: stateResidency,
                   subscription: subscription, channels: channels)
    }

    /// Average clock since the previous call. Nil on the first call and after
    /// a long gap (popover closed), where the average would be long out of date.
    func read() -> Double? {
        guard let api, let current = api.createSamples(api.subscription, api.channels, nil)?.takeRetainedValue() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let isRecent = now - previousTime < Self.maxSampleGap
        defer {
            previous = current
            previousTime = now
        }
        guard isRecent, let previous, let delta = api.createDelta(previous, current, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }
        for item in items {
            let channel = item as CFDictionary
            guard api.channelName(channel)?.takeUnretainedValue() as String? == "GPUPH" else { continue }
            let residencies = (0..<api.stateCount(channel)).map { api.stateResidency(channel, $0) }
            return GPUClock.averageGHz(residencies: residencies, frequenciesHz: frequenciesHz)
        }
        return nil
    }
}

/// Reads die temperature from the private IOHIDEventSystem sensors, looked up
/// at runtime. Apple silicon exposes no GPU-specific sensor through it, so
/// this averages the SoC's `tdie` sensors. Empty on Intel.
final class TemperatureReader {
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias EventFloat = @convention(c) (CFTypeRef, Int32) -> Double

    private let copyEvent: CopyEvent?
    private let eventFloat: EventFloat?
    private let client: CFTypeRef?
    private let sensors: [CFTypeRef]

    init() {
        typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
        typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
        typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
        typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
        let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
        }
        copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self)
        eventFloat = symbol("IOHIDEventGetFloatValue", as: EventFloat.self)
        guard let create = symbol("IOHIDEventSystemClientCreate", as: CreateClient.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else {
            client = nil
            sensors = []
            return
        }
        self.client = client
        // Apple's vendor usage page and usage for temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        sensors = services.filter { service in
            let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String
            return name?.contains("tdie") == true
        }
    }

    func read() -> Double? {
        guard let copyEvent, let eventFloat else { return nil }
        let temperatureEvent: Int64 = 15
        let readings = sensors.compactMap { sensor in
            copyEvent(sensor, temperatureEvent, 0, 0)?.takeRetainedValue()
        }.map { eventFloat($0, Int32(temperatureEvent << 16)) }.filter { $0 > 0 }
        return readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)
    }
}

/// Produces `Snapshot`s. Only ever used from one serial queue.
final class SystemSampler: @unchecked Sendable {
    let groups: [CoreGroup]
    private let memorySize = Double(ProcessInfo.processInfo.physicalMemory)
    private var previousTicks: [CoreTicks] = []
    private lazy var gpuClock = GPUClockReader()
    private lazy var temperature = TemperatureReader()
    private var processes: [ProcessUsage] = []
    private var processesTime: TimeInterval = -.infinity
    private static let processInterval: TimeInterval = 3

    init() {
        let levels = (0..<(sysctlInt("hw.nperflevels") ?? 0)).reversed().compactMap { level -> (name: String, count: Int)? in
            guard let name = sysctlString("hw.perflevel\(level).name"),
                  let count = sysctlInt("hw.perflevel\(level).logicalcpu") else { return nil }
            return (name, count)
        }
        groups = CoreGroup.make(levels: levels, total: ProcessInfo.processInfo.processorCount)
    }

    /// Nil on the first call: usage is a difference between two readings.
    func sample(detailed: Bool) -> Snapshot? {
        let ticks = Self.readTicks()
        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count, !ticks.isEmpty else { return nil }
        let time = ProcessInfo.processInfo.systemUptime
        let gpu = readGPU()
        return Snapshot(time: time,
                        cores: zip(previousTicks, ticks).map(CoreUsage.between),
                        gpuUtilization: gpu.utilization,
                        gpuMemory: gpu.memory,
                        load: Self.readLoad(),
                        uptime: Self.readUptime(),
                        detail: detailed ? readDetail(at: time) : nil)
    }

    private static func readTicks() -> [CoreTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        // The kernel allocates this in our address space on every call.
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * Int(CPU_STATE_MAX)
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return CoreTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                             idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    private func readGPU() -> (utilization: Double?, memory: Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return (nil, nil) }
        return ((stats["Device Utilization %"] as? Double).map { $0 / 100 },
                (stats["In use system memory"] as? Double).map { $0 / memorySize })
    }

    private static func readLoad() -> [Double] {
        var load = [Double](repeating: 0, count: 3)
        return getloadavg(&load, 3) == 3 ? load : []
    }

    /// From the boot time, not `systemUptime`, which stops while the Mac sleeps.
    private static func readUptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - TimeInterval(boot.tv_sec)
    }

    private func readDetail(at time: TimeInterval) -> Snapshot.Detail {
        // ps is the one subprocess here, so it runs less often. It's setuid
        // root, so unlike libproc it can also see root-owned processes.
        if time - processesTime >= Self.processInterval,
           case let .success(output) = CommandRunner.run("/bin/ps", ["-Ao", "pcpu=,comm="], timeout: 2) {
            processes = ProcessParser.top(psOutput: output, coreCount: ProcessInfo.processInfo.processorCount, limit: 3)
            processesTime = time
        }
        return Snapshot.Detail(processes: processes, temperature: temperature.read(),
                               gigahertz: gpuClock.read(), maxGigahertz: gpuClock.maxGHz)
    }
}

/// A series on the dashboard graph.
struct MetricSeries {
    let name: String
    let color: NSColor
    /// Timestamped values in percent (nil = unavailable), oldest first. The
    /// graph positions points by time, so the line scrolls continuously.
    var samples: [(time: TimeInterval, value: Double?)] = []

    var latest: Double? { samples.last?.value }

    mutating func add(_ value: Double?, at time: TimeInterval) {
        samples.append((time, value))
    }

    /// Drops samples older than `cutoff`, keeping one just before it so the
    /// line slides in from the left edge instead of popping into view.
    mutating func prune(before cutoff: TimeInterval) {
        while samples.count > 1, samples[1].time < cutoff {
            samples.removeFirst()
        }
    }
}

final class MetricGraphView: NSView {
    var series: [MetricSeries] = []
    /// Current time (system uptime); advanced every frame so lines scroll
    /// continuously rather than stepping when a sample arrives.
    var now: TimeInterval = ProcessInfo.processInfo.systemUptime

    /// Seconds of history visible across the graph's width.
    static let visibleWindow: TimeInterval = 60
    /// The right edge shows the state from this many seconds ago — more than
    /// the sample interval — so the newest stretch of line is almost always
    /// between two known samples and never reshapes.
    static let displayDelay: TimeInterval = 2

    private let backgroundColor = Palette.canvas
    private let gridColor = NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.07)
    private let axisTextColor = NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.45)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bounds = self.bounds

        // Dark rounded canvas.
        let canvas = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        backgroundColor.setFill()
        canvas.fill()

        guard !series.isEmpty else { return }

        let leftPad: CGFloat = 64
        let topPad: CGFloat = 48
        let bottomPad: CGFloat = 32
        let labelGutter: CGFloat = 180
        let rightPad: CGFloat = 16
        let graphRect = NSRect(
            x: leftPad,
            y: bottomPad,
            width: bounds.width - leftPad - labelGutter - rightPad,
            height: bounds.height - topPad - bottomPad
        )
        guard graphRect.width > 40, graphRect.height > 40 else { return }

        drawTitle("CPU USAGE OVER TIME", at: CGPoint(x: leftPad, y: bounds.maxY - 32))

        let span = MetricGraphView.visibleWindow
        let headTime = now - MetricGraphView.displayDelay

        func point(_ time: TimeInterval, _ value: Double) -> CGPoint {
            let x = graphRect.maxX - CGFloat((headTime - time) / span) * graphRect.width
            let y = graphRect.minY + CGFloat(value / 100) * graphRect.height
            return CGPoint(x: x, y: y)
        }

        drawGrid(ctx, in: graphRect)

        let colorSpace = CGColorSpaceCreateDeviceRGB()

        var labels: [FloatingLabel] = []

        // Lines extend past both edges of the plot (older samples on the left,
        // samples newer than headTime on the right); clip them horizontally.
        ctx.saveGState()
        ctx.clip(to: NSRect(x: graphRect.minX, y: bounds.minY, width: graphRect.width, height: bounds.height))

        for line in series {
            // Split into contiguous segments so unavailable readings break the
            // line instead of plunging it to the floor.
            var segments: [[CGPoint]] = []
            var current: [CGPoint] = []
            for sample in line.samples {
                if let value = sample.value {
                    current.append(point(sample.time, value))
                } else if !current.isEmpty {
                    segments.append(current)
                    current = []
                }
            }
            // A late sample holds its last value flat up to the right edge.
            if let last = line.samples.last, let value = last.value, last.time < headTime {
                current.append(point(headTime, value))
            }
            if !current.isEmpty { segments.append(current) }
            guard !segments.isEmpty else { continue }

            for pts in segments {
                drawAreaFill(ctx, points: pts, baseline: graphRect.minY,
                             top: graphRect.maxY, color: line.color, colorSpace: colorSpace)
                drawGlowLine(ctx, points: pts, color: line.color)
            }

            // The line's visible end: where it crosses the right edge.
            guard let segment = segments.last(where: { $0[0].x <= graphRect.maxX }),
                  let end = curvePoint(on: segment, atX: graphRect.maxX) ?? segment.last(where: { $0.x <= graphRect.maxX }),
                  end.x >= graphRect.minX else { continue }
            labels.append(FloatingLabel(text: labelText(for: line), color: line.color, anchor: end))
        }

        ctx.restoreGState()

        for label in labels {
            drawEndDot(ctx, at: label.anchor, color: label.color)
        }

        drawFloatingLabels(ctx, labels, graphRect: graphRect)
    }

    private struct FloatingLabel {
        let text: String
        let color: NSColor
        let anchor: CGPoint
    }

    private func labelText(for line: MetricSeries) -> String {
        guard let value = line.latest else { return line.name }
        return "\(line.name)  \(Int(value.rounded()))%"
    }

    /// Draws each series' label floating next to the end of its line. Labels
    /// are nudged apart vertically so they stay readable when lines cluster,
    /// with a faint connector back to the line's last point.
    private func drawFloatingLabels(_ ctx: CGContext, _ labels: [FloatingLabel], graphRect: NSRect) {
        guard !labels.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let lineHeight = font.ascender - font.descender
        let minGap = lineHeight + 4
        let labelX = graphRect.maxX + 14

        // Resolve vertical collisions from the top down.
        let placed = labels.sorted { $0.anchor.y > $1.anchor.y }
        var ys = placed.map { $0.anchor.y }
        for i in 1..<ys.count where ys[i - 1] - ys[i] < minGap {
            ys[i] = ys[i - 1] - minGap
        }
        // Keep the stack inside the canvas.
        let overflow = graphRect.minY - (ys.last ?? graphRect.minY)
        if overflow > 0 { for i in ys.indices { ys[i] += overflow } }

        for (i, label) in placed.enumerated() {
            let y = ys[i]

            // Connector from the line's end point to the label.
            ctx.saveGState()
            ctx.setStrokeColor(label.color.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: label.anchor)
            ctx.addLine(to: CGPoint(x: labelX - 4, y: y))
            ctx.strokePath()
            ctx.restoreGState()

            NSAttributedString(string: label.text, attributes: [
                .font: font,
                .foregroundColor: label.color
            ]).draw(at: CGPoint(x: labelX, y: y - lineHeight / 2))
        }
    }

    private func drawTitle(_ text: String, at origin: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.75),
            .kern: 2.0
        ]
        NSAttributedString(string: text, attributes: attrs)
            .draw(at: origin)
    }

    private func drawGrid(_ ctx: CGContext, in rect: NSRect) {
        ctx.setLineWidth(1)
        for i in 0...5 {
            let y = rect.minY + CGFloat(i) * rect.height / 5
            ctx.setStrokeColor(gridColor.cgColor)
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            ctx.strokePath()

            let label = NSAttributedString(string: "\(i * 20)%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: axisTextColor
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: rect.minX - size.width - 8, y: y - size.height / 2))
        }
    }

    private func drawAreaFill(_ ctx: CGContext, points: [CGPoint], baseline: CGFloat,
                              top: CGFloat, color: NSColor, colorSpace: CGColorSpace) {
        guard points.count >= 2 else { return }
        ctx.saveGState()
        let fill = CGMutablePath()
        fill.move(to: CGPoint(x: points[0].x, y: baseline))
        fill.addLine(to: points[0])
        Self.addSmoothCurve(to: fill, through: points)
        fill.addLine(to: CGPoint(x: points.last!.x, y: baseline))
        fill.closeSubpath()
        ctx.addPath(fill)
        ctx.clip()

        let gradient = CGGradient(colorsSpace: colorSpace,
                                  colors: [color.withAlphaComponent(0.40).cgColor,
                                           color.withAlphaComponent(0.0).cgColor] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: top),
                               end: CGPoint(x: 0, y: baseline),
                               options: [])
        ctx.restoreGState()
    }

    private func drawGlowLine(_ ctx: CGContext, points: [CGPoint], color: NSColor) {
        guard !points.isEmpty else { return }
        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        let line = CGMutablePath()
        line.move(to: points[0])
        Self.addSmoothCurve(to: line, through: points)
        // The glow is a few wide translucent strokes under the line rather than
        // a shadow blur: CG computes shadows with a CPU convolution every
        // frame, which made the blur most of the visible window's CPU cost.
        for (width, alpha) in [(14.0, 0.06), (9.0, 0.10), (5.5, 0.22), (2.5, 1.0)] as [(CGFloat, CGFloat)] {
            ctx.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(width)
            ctx.addPath(line)
            ctx.strokePath()
        }
        ctx.restoreGState()

        if points.count == 1 {
            drawEndDot(ctx, at: points[0], color: color)
        }
    }

    /// Appends a Catmull-Rom spline through `points` to `path`, which must
    /// already be positioned at `points[0]`. Produces smooth curved lines.
    static func addSmoothCurve(to path: CGMutablePath, through points: [CGPoint]) {
        guard points.count > 1 else { return }
        guard points.count > 2 else {
            path.addLine(to: points[1])
            return
        }
        for i in 0..<(points.count - 1) {
            let (c1, c2) = Self.controlPoints(points, segment: i)
            path.addCurve(to: points[i + 1], control1: c1, control2: c2)
        }
    }

    /// Bezier control points of the Catmull-Rom segment from points[i] to points[i + 1].
    private static func controlPoints(_ points: [CGPoint], segment i: Int) -> (CGPoint, CGPoint) {
        let p0 = points[max(i - 1, 0)]
        let p1 = points[i]
        let p2 = points[i + 1]
        let p3 = points[min(i + 2, points.count - 1)]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
        return (c1, c2)
    }

    /// The point where the smooth curve through `points` crosses `x`, so the
    /// end dot sits exactly on the drawn line. Nil if the curve doesn't span `x`.
    private func curvePoint(on points: [CGPoint], atX x: CGFloat) -> CGPoint? {
        guard points.count >= 2,
              let i = points.indices.dropLast().first(where: { points[$0].x <= x && x <= points[$0 + 1].x })
        else { return nil }
        let p1 = points[i]
        let p2 = points[i + 1]
        guard points.count > 2 else {
            let t = p2.x > p1.x ? (x - p1.x) / (p2.x - p1.x) : 1
            return CGPoint(x: x, y: p1.y + (p2.y - p1.y) * t)
        }
        let (c1, c2) = Self.controlPoints(points, segment: i)
        // x(t) is close to linear for evenly spaced samples, so use the x
        // fraction as the curve parameter.
        let t = p2.x > p1.x ? (x - p1.x) / (p2.x - p1.x) : 1
        let u = 1 - t
        let y = u * u * u * p1.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p2.y
        return CGPoint(x: x, y: y)
    }

    private func drawEndDot(_ ctx: CGContext, at point: CGPoint, color: NSColor) {
        // Halo rings instead of a shadow blur, for the same reason as drawGlowLine.
        for (r, alpha) in [(11.0, 0.08), (7.5, 0.18), (4.0, 1.0)] as [(CGFloat, CGFloat)] {
            ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        }

        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3))
    }

}

enum Palette {
    static let canvas = NSColor(calibratedRed: 0.055, green: 0.067, blue: 0.10, alpha: 1)
    static let blue = NSColor(srgbRed: 0.36, green: 0.36, blue: 1.00, alpha: 1)
    static let pink = NSColor(srgbRed: 0.93, green: 0.27, blue: 0.60, alpha: 1)
    static let text = NSColor.white.withAlphaComponent(0.92)
    static let track = NSColor.white.withAlphaComponent(0.13)
}

/// The popover's dark status panel. Everything is drawn in one view, redrawn
/// once per sample, so an open popover needs no frame timer.
final class CPUPanelView: NSView {
    var snapshot: Snapshot?
    /// Latest detail received; a snapshot only carries it while the popover is open.
    var detail = Snapshot.Detail()
    /// Whole-CPU usage, oldest first, at most `historyLength` entries.
    var history: [CoreUsage] = []
    var refreshRate: Int?

    static let historyLength = 60
    private static let width: CGFloat = 300
    private static let inset: CGFloat = 16
    private static let processRows = 3

    private let groups: [CoreGroup]
    private var icons: [String: NSImage] = [:]

    init(groups: [CoreGroup]) {
        self.groups = groups
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.width, height: Self.height(groupCount: groups.count))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: Self.height(groupCount: groups.count))
    }

    private static func height(groupCount: Int) -> CGFloat {
        var y: CGFloat = 0
        layout(&y, groupCount: groupCount)
        return y
    }

    /// Every section's top edge. `draw` and the view's height share this, so
    /// they can't disagree.
    private struct Layout {
        var cpuHeader: CGFloat = 0, bars: CGFloat = 0, legend: CGFloat = 0, rings: CGFloat = 0, groups: CGFloat = 0
        var processHeader: CGFloat = 0, processes: CGFloat = 0, gpuHeader: CGFloat = 0, gpuRings: CGFloat = 0
        var load: CGFloat = 0, uptime: CGFloat = 0
    }
    private static let barsHeight: CGFloat = 52
    private static let coreRingSize: CGFloat = 18
    private static let gpuRingSize: CGFloat = 58
    private static let rowHeight: CGFloat = 19

    @discardableResult
    private static func layout(_ y: inout CGFloat, groupCount: Int) -> Layout {
        var result = Layout()
        y = 14
        result.cpuHeader = y; y += 22
        result.bars = y; y += barsHeight + 6
        result.legend = y; y += rowHeight + 10
        result.rings = y; y += coreRingSize + 8
        result.groups = y; y += CGFloat(groupCount) * rowHeight + 14
        result.processHeader = y; y += 22
        result.processes = y; y += CGFloat(processRows) * rowHeight + 14
        result.gpuHeader = y; y += 24
        result.gpuRings = y; y += gpuRingSize + 16
        result.load = y; y += rowHeight + 8
        result.uptime = y; y += rowHeight + 10
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Palette.canvas.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        var end: CGFloat = 0
        let at = Self.layout(&end, groupCount: groups.count)
        let left = Self.inset
        let right = bounds.width - Self.inset
        let cpu = snapshot?.cpu

        // CPU: stacked user/system history, newest on the right.
        drawHeader("CPU", y: at.cpuHeader)
        drawBars(ctx, in: NSRect(x: left, y: at.bars, width: right - left, height: Self.barsHeight))
        let middle = bounds.midX + 2
        drawLegend("User", color: Palette.blue, value: cpu.map { Format.percent($0.user) }, y: at.legend, from: left, to: middle - 10)
        drawLegend("System", color: Palette.pink, value: cpu.map { Format.percent($0.system) }, y: at.legend, from: middle, to: right)

        // One ring per core, slowest cores first.
        let coreCount = max(groups.map(\.cores.upperBound).max() ?? 0, 1)
        let step = (right - left - Self.coreRingSize) / CGFloat(max(coreCount - 1, 1))
        for group in groups {
            let color = coreColor(group)
            for core in group.cores {
                let value = snapshot.flatMap { $0.cores.indices.contains(core) ? $0.cores[core].total : nil }
                let rect = NSRect(x: left + CGFloat(core) * step, y: at.rings, width: Self.coreRingSize, height: Self.coreRingSize)
                drawRing(ctx, in: rect, fraction: value, color: color, lineWidth: 3)
            }
        }
        for (index, group) in groups.enumerated() {
            let usage = snapshot.map { CoreUsage.average($0.cores[group.cores.clamped(to: $0.cores.indices)]) }
            drawLegend("\(group.name) Cores", color: coreColor(group), value: usage.map { Format.percent($0.total) },
                       y: at.groups + CGFloat(index) * Self.rowHeight, from: left, to: right)
        }

        drawHeader("PROCESSES", y: at.processHeader)
        for (index, process) in detail.processes.prefix(Self.processRows).enumerated() {
            let y = at.processes + CGFloat(index) * Self.rowHeight
            icon(for: process).draw(in: NSRect(x: left, y: y + 1, width: 15, height: 15), from: .zero,
                                    operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let value = String(format: "%.1f%%", locale: .current, process.percent)
            let valueWidth = drawText(value, x: right, y: y, alignRight: true)
            drawText(process.name, x: left + 21, y: y, maxWidth: right - left - 21 - valueWidth - 8)
        }

        // GPU: four rings, each scaled to that metric's own range.
        drawHeader("GPU", y: at.gpuHeader)
        if let refreshRate { drawText("\(refreshRate) Hz", x: right, y: at.gpuHeader, alignRight: true) }
        let ghz = detail.gigahertz
        let rings: [(label: String, value: String, fraction: Double?)] = [
            ("GPU", snapshot?.gpuUtilization.map(Format.percent) ?? "-", snapshot?.gpuUtilization),
            ("MEM", snapshot?.gpuMemory.map(Format.percent) ?? "-", snapshot?.gpuMemory),
            ("TMP", detail.temperature.map { String(format: "%.0f°", $0) } ?? "-", detail.temperature.map { $0 / 100 }),
            ("GHZ", ghz.map { String(format: "%.2f", locale: .current, $0) } ?? "-",
             ghz.flatMap { value in detail.maxGigahertz.map { value / $0 } })
        ]
        let ringStep = (right - left - Self.gpuRingSize) / CGFloat(rings.count - 1)
        for (index, ring) in rings.enumerated() {
            let rect = NSRect(x: left + CGFloat(index) * ringStep, y: at.gpuRings, width: Self.gpuRingSize, height: Self.gpuRingSize)
            drawRing(ctx, in: rect, fraction: ring.fraction, color: Palette.blue, lineWidth: 4)
            drawCentered(ring.value, size: 13, weight: .semibold, color: Palette.text, centerX: rect.midX, centerY: rect.midY - 5)
            drawCentered(ring.label, size: 8, weight: .medium, color: NSColor.white.withAlphaComponent(0.6), centerX: rect.midX, centerY: rect.midY + 9)
        }

        drawHeader("LOAD", y: at.load)
        drawText(snapshot.map { Format.load($0.load) } ?? "-", x: right, y: at.load, alignRight: true)
        drawHeader("UPTIME", y: at.uptime)
        drawText(snapshot.map { Format.uptime(seconds: $0.uptime) } ?? "-", x: right, y: at.uptime, alignRight: true)
    }

    /// Efficiency-style cores are pink, the fastest cores (or all, on Intel) blue.
    private func coreColor(_ group: CoreGroup) -> NSColor {
        group == groups.last ? Palette.blue : Palette.pink
    }

    private func icon(for process: ProcessUsage) -> NSImage {
        let key = process.iconPath ?? process.name
        if let cached = icons[key] { return cached }
        let image: NSImage
        if process.name == ProcessParser.systemName {
            image = NSImage(named: NSImage.computerName) ?? NSImage()
        } else if let path = process.iconPath {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        icons[key] = image
        return image
    }

    private func drawBars(_ ctx: CGContext, in rect: NSRect) {
        ctx.setFillColor(Palette.track.cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
        let slot = rect.width / CGFloat(Self.historyLength)
        for (age, usage) in history.reversed().enumerated() where age < Self.historyLength {
            let x = rect.maxX - CGFloat(age + 1) * slot
            let barWidth = max(slot - 1, 1)
            let userHeight = CGFloat(usage.user) * rect.height
            let systemHeight = CGFloat(usage.system) * rect.height
            ctx.setFillColor(Palette.blue.cgColor)
            ctx.fill(CGRect(x: x, y: rect.maxY - userHeight, width: barWidth, height: userHeight))
            ctx.setFillColor(Palette.pink.cgColor)
            ctx.fill(CGRect(x: x, y: rect.maxY - userHeight - systemHeight, width: barWidth, height: systemHeight))
        }
    }

    /// A track with an arc filling clockwise from the top; no arc when `fraction` is nil.
    private func drawRing(_ ctx: CGContext, in rect: NSRect, fraction: Double?, color: NSColor, lineWidth: CGFloat) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2 - lineWidth / 2
        ctx.setLineWidth(lineWidth)
        ctx.setStrokeColor(Palette.track.cgColor)
        ctx.strokeEllipse(in: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        guard let fraction, fraction > 0 else { return }
        let start = -CGFloat.pi / 2
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineCap(.round)
        // This view is flipped, so increasing angles run clockwise on screen.
        ctx.addArc(center: center, radius: radius, startAngle: start,
                   endAngle: start + 2 * .pi * CGFloat(min(fraction, 1)), clockwise: false)
        ctx.strokePath()
    }

    private func drawHeader(_ text: String, y: CGFloat) {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: Palette.blue,
            .kern: 0.4
        ]).draw(at: CGPoint(x: Self.inset, y: y))
    }

    private func drawLegend(_ label: String, color: NSColor, value: String?, y: CGFloat, from: CGFloat, to: CGFloat) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: from, y: y + 4, width: 8, height: 8)).fill()
        drawText(label, x: from + 13, y: y)
        drawText(value ?? "-", x: to, y: y, alignRight: true)
    }

    @discardableResult
    private func drawText(_ text: String, x: CGFloat, y: CGFloat, alignRight: Bool = false, maxWidth: CGFloat? = nil) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: Palette.text,
            .paragraphStyle: paragraph
        ])
        let size = string.size()
        let width = maxWidth.map { min($0, size.width) } ?? size.width
        string.draw(in: NSRect(x: alignRight ? x - width : x, y: y, width: width, height: size.height))
        return width
    }

    private func drawCentered(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerX: CGFloat, centerY: CGFloat) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ])
        let textSize = string.size()
        string.draw(at: CGPoint(x: centerX - textSize.width / 2, y: centerY - textSize.height / 2))
    }
}

@MainActor
final class DashboardController: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var graphView: MetricGraphView!
    private var footerLabel: NSTextField!
    private let sampler = SystemSampler()
    private let sampleQueue = DispatchQueue(label: "sampler", qos: .utility)
    private var sampleTimer: Timer?
    private var isSampling = false
    private var series: [MetricSeries] = []
    // Redraws the graph every frame so it scrolls continuously; samples are
    // only recorded once a second.
    private var frameTimer: Timer?
    // Menu bar presence: the app has no Dock icon and lives here instead.
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var panel: CPUPanelView!
    private var outsideClickMonitor: Any?
    private var lastHealth: NSColor?
    private enum UpdateState: Equatable {
        case idle, available(Updater.Release), installing, failed(Updater.Release, String)
    }
    private var updateState = UpdateState.idle
    private var updateButton: NSButton!
    private var updateTimer: Timer?

    private var buildNumber: Int {
        // Inside a .app bundle (built by bundle.sh) the working directory isn't
        // the repo, so the git count is baked into Info.plist at bundle time.
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           let intValue = Int(version) {
            return intValue
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-list", "--count", "HEAD"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            if let count = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let intValue = Int(count) {
                return intValue
            }
        } catch {
            return 0
        }
        return 0
    }

    private var versionString: String {
        "v1.0.\(buildNumber)"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildSeries()
        buildWindow()
        buildStatusItem()
        startSampling()
        startUpdateChecks()
        // Async so launch finishes before the dialog's modal loop starts.
        DispatchQueue.main.async { LoginItem.offerIfNeeded() }
        // No frame timer yet: it only runs while the dashboard is visible
        // (see startFrameTimer/stopFrameTimerIfIdle).
    }

    private func buildSeries() {
        series = [
            MetricSeries(name: "Total", color: .systemGreen),
            MetricSeries(name: "User", color: .systemBlue),
            MetricSeries(name: "System", color: .systemPink)
        ]
        // With a single group, its line would just repeat Total.
        if sampler.groups.count > 1 {
            let colors: [NSColor] = [.systemOrange, .systemPurple, .systemTeal]
            for (index, group) in sampler.groups.enumerated() {
                series.append(MetricSeries(name: group.name, color: colors[index % colors.count]))
            }
        }
        series.append(MetricSeries(name: "GPU", color: .systemYellow))
    }

    private func startFrameTimer() {
        guard frameTimer == nil else { return }
        // .common mode keeps frames coming during live resize; assumeIsolated
        // (not a Task per frame) avoids scheduling jitter.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    /// Stops the 60 Hz timer when the graph isn't on screen, so the app doesn't
    /// wake 60 times a second while it sits in the menu bar.
    private func stopFrameTimerIfIdle() {
        guard !(window.isVisible && window.occlusionState.contains(.visible)) else { return }
        frameTimer?.invalidate()
        frameTimer = nil
    }

    // Covers every way the window appears or disappears: open, close,
    // minimize, Space switches, and being covered by other windows.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window.isVisible && window.occlusionState.contains(.visible) {
            startFrameTimer()
        } else {
            stopFrameTimerIfIdle()
        }
    }

    // Closing the window just hides it; the app keeps sampling in the menu bar.
    // Launching the app again while it's running (Finder, Spotlight, `open`)
    // shows the dashboard, as is usual for menu bar apps.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true  // no backing store (or ~16 MB graph drawable) until first shown
        )
        window.title = "Cpuline \(versionString)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        footerLabel = NSTextField(labelWithString: "Starting...")
        footerLabel.textColor = .secondaryLabelColor

        graphView = MetricGraphView()
        graphView.wantsLayer = true
        graphView.series = series
        graphView.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.documentView = graphView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder

        // Pin the graph to fill the visible area so the dark canvas always
        // covers the bezel and the chart scales to the window.
        NSLayoutConstraint.activate([
            graphView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            graphView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            graphView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            graphView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor)
        ])

        root.addArrangedSubview(scrollView)
        root.addArrangedSubview(footerLabel)

        window.contentView = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420)
        ])
        // Not shown at launch: the app starts as a menu bar icon only, and the
        // window appears via the "Dashboard" button.
    }

    private func startSampling() {
        requestSample()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestSample() }
        }
        timer.tolerance = 0.1
        sampleTimer = timer
    }

    /// Takes one sample off the main thread. The costlier details (ps, GPU
    /// clock, temperature) are only read while the popover can show them.
    private func requestSample() {
        guard !isSampling else { return }
        isSampling = true
        let sampler = self.sampler
        let detailed = popover.isShown
        sampleQueue.async {
            let snapshot = sampler.sample(detailed: detailed)
            Task { @MainActor in
                self.isSampling = false
                if let snapshot { self.apply(snapshot) }
            }
        }
    }

    /// Advances the graph's clock and redraws it — only while the window is
    /// actually on screen, so the menu-bar-only state stays near idle.
    private func renderFrame() {
        guard window.isVisible, window.occlusionState.contains(.visible) else { return }
        graphView.now = ProcessInfo.processInfo.systemUptime
        graphView.needsDisplay = true
    }

    private func apply(_ snapshot: Snapshot) {
        let cpu = snapshot.cpu
        var values: [Double?] = [cpu.total * 100, cpu.user * 100, cpu.system * 100]
        if sampler.groups.count > 1 {
            values += sampler.groups.map { group -> Double? in
                CoreUsage.average(snapshot.cores[group.cores.clamped(to: snapshot.cores.indices)]).total * 100
            }
        }
        values.append(snapshot.gpuUtilization.map { $0 * 100 })
        for index in series.indices {
            series[index].add(values[index], at: snapshot.time)
            series[index].prune(before: snapshot.time - MetricGraphView.displayDelay - MetricGraphView.visibleWindow)
        }
        graphView.series = series

        panel.snapshot = snapshot
        panel.history.append(cpu)
        if panel.history.count > CPUPanelView.historyLength { panel.history.removeFirst() }
        if let detail = snapshot.detail { panel.detail = detail }
        if popover.isShown { panel.needsDisplay = true }

        footerLabel.stringValue = "Total: \(Format.percent(cpu.total))   User: \(Format.percent(cpu.user))   System: \(Format.percent(cpu.system))   Load: \(Format.load(snapshot.load))   Uptime: \(Format.uptime(seconds: snapshot.uptime))"
        panel.setAccessibilityLabel(footerLabel.stringValue)
        updateStatusIcon(total: cpu.total)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)

        panel = CPUPanelView(groups: sampler.groups)
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.staticText)
        panel.widthAnchor.constraint(equalToConstant: panel.intrinsicContentSize.width).isActive = true
        panel.heightAnchor.constraint(equalToConstant: panel.intrinsicContentSize.height).isActive = true

        let openButton = NSButton(title: "Dashboard", target: self, action: #selector(openDashboard))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded
        updateButton = NSButton(title: "", target: self, action: #selector(updateClicked))
        updateButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [quitButton, NSView(), updateButton, openButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let stack = NSStackView(views: [panel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 7, bottom: 7, right: 7)
        buttons.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true

        let content = NSViewController()
        content.view = stack
        // Without this the popover opens narrower than its content, squeezing out the side margins.
        content.preferredContentSize = stack.fittingSize
        popover.contentViewController = content

        renderUpdateState()
        updateStatusIcon(total: nil)
    }

    /// Colors the menu bar icon by total CPU use: green below 50%, orange below
    /// 85%, red above, gray before the first sample.
    private func updateStatusIcon(total: Double?) {
        let health: NSColor
        switch total {
        case nil: health = .systemGray
        case let total? where total < 0.5: health = .systemGreen
        case let total? where total < 0.85: health = .systemOrange
        default: health = .systemRed
        }
        // Only swap the image when the color changes: re-rendering the SF
        // Symbol on every sample would be the app's main idle CPU cost.
        guard health != lastHealth else { return }
        lastHealth = health
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [health]))
        statusItem.button?.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Cpuline")?
            .withSymbolConfiguration(config)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            // Deliberately not activating the app: that would raise the
            // dashboard window along with the popover. Without activation,
            // transient popovers don't see clicks in other apps, so close on
            // those via a global monitor (mouse monitors need no accessibility
            // permission).
            panel.refreshRate = NSScreen.main?.maximumFramesPerSecond
            panel.needsDisplay = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Fill in the details now rather than at the next tick.
            requestSample()
            // A late popoverDidClose could otherwise drop the new token and leak the old monitor.
            if let monitor = outsideClickMonitor {
                NSEvent.removeMonitor(monitor)
            }
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.popover.performClose(nil) }
            }
        }
    }

    // The window is kept for reuse, but its layer-backed graph would keep a
    // ~16 MB drawable alive while hidden; drop it. The first visible frame
    // after reopening redraws it.
    func windowWillClose(_ notification: Notification) {
        graphView.layer?.contents = nil
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    @objc private func openDashboard() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Also started by the occlusion callback; this guarantees it on first show.
        startFrameTimer()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Checks shortly after launch and then daily; a failed check changes
    /// nothing. The timer's only idle cost is one wakeup a day.
    private func startUpdateChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForUpdates()
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdates() }
        }
        timer.tolerance = 60 * 60
        updateTimer = timer
    }

    private func checkForUpdates() {
        guard updateState != .installing else { return }
        let currentBuild = buildNumber
        DispatchQueue.global(qos: .utility).async {
            guard let latest = try? Updater.fetchLatest(), latest.build > currentBuild else { return }
            Task { @MainActor in
                guard self.updateState != .installing else { return }
                self.setUpdateState(.available(latest))
            }
        }
    }

    @objc private func updateClicked() {
        let release: Updater.Release
        switch updateState {
        case let .available(found), let .failed(found, _): release = found
        case .idle, .installing: return
        }
        let bundleURL = Bundle.main.bundleURL
        guard Updater.canInstall(over: bundleURL) else {
            NSWorkspace.shared.open(Updater.releasePageURL)
            return
        }
        setUpdateState(.installing)
        let pid = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Updater.install(release, over: bundleURL, pid: pid) }
            Task { @MainActor in
                switch result {
                case .success: NSApp.terminate(nil)
                case let .failure(error): self.setUpdateState(.failed(release, error.localizedDescription))
                }
            }
        }
    }

    private func setUpdateState(_ state: UpdateState) {
        updateState = state
        renderUpdateState()
    }

    /// The button only shows when there's something to install.
    private func renderUpdateState() {
        updateButton.isHidden = updateState == .idle
        updateButton.isEnabled = updateState != .installing
        switch updateState {
        case .idle:
            break
        case let .available(release):
            updateButton.title = "Update"
            updateButton.toolTip = "Update to \(release.version)"
        case .installing:
            updateButton.title = "Updating…"
            updateButton.toolTip = nil
        case let .failed(_, message):
            updateButton.title = "Retry"
            updateButton.toolTip = message
        }
    }
}

/// Accessory apps show no menu bar, but the main menu's key equivalents still
/// work while the app is active.
@MainActor
func buildMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    mainMenu.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    mainMenu.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu

    return mainMenu
}

let app = NSApplication.shared
app.mainMenu = buildMainMenu()
let delegate = DashboardController()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
