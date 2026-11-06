# CLAUDE.md

Native macOS menu bar app (AppKit, Swift 6) tracking CPU usage per core, top processes, GPU, load, and uptime. Started as a copy of Reachline; it shares that app's graph, updater, and login-item code but no history.

## Commands
- Run in dev: `swift run Cpuline`
- Build release: `swift build --configuration release`
- Build+run latest (pulls origin, clean rebuild): `./run.sh`
- Package `.app` (universal, ad-hoc signed): `./bundle.sh`; publish a GitHub release `v1.0.<commit count>` with the zipped app: `./release.sh` (needs a clean tree pushed to `main`)
- Run unit tests: `swift test` (Swift Testing, in `Tests/CpulineTests/`). Requires full Xcode installed (not just Command Line Tools) — without it, `swift test` can't locate the `Testing` framework.
- Launch a build without touching real settings: `CFFIXED_USER_HOME=<tmp dir> .build/Cpuline.app/Contents/MacOS/Cpuline`
- Measure memory with `footprint <pid>`, not RSS, which includes shared system memory and reads far higher.
- Without Xcode, test logic by copying the types into a scratch `swiftc` harness; replace `open` in `Updater.swapScript` there so no test copy launches.

## Architecture
Single file: `Sources/Cpuline/main.swift`.
- `CoreUsage`, `CoreGroup`, `ProcessParser`, `Format`, `GPUClock` — pure logic, unit-tested
- `SystemSampler` — produces a `Snapshot` per second on one serial queue: `host_processor_info` ticks, `IOAccelerator` `PerformanceStatistics`, `getloadavg`, `kern.boottime`. While the popover is open it adds `Snapshot.Detail`: `/bin/ps`, `GPUClockReader` (private libIOReport), `TemperatureReader` (private IOHIDEventSystemClient)
- `MetricGraphView` — custom NSView drawing the neon multi-line graph (Catmull-Rom smoothing, glow, floating labels), fixed at 0–100%
- `CPUPanelView` — the popover's dark panel, all drawn in one view
- `Updater` — checks GitHub for the latest release, then downloads, verifies, and swaps in the new app using a detached shell script that waits for the app to quit. `parseRelease` is pure and unit-tested
- `LoginItem` — asks once at launch (remembered in `UserDefaults`) whether to register with `SMAppService.mainApp`; only when installed in an Applications folder
- `DashboardController` — AppKit app delegate; owns the window, the menu bar status item/popover, and the sample timer. Runs as an accessory app (no Dock icon); closing the window keeps it running, quit from the popover

## Gotchas
- `CoreGroup` assumes logical CPUs are numbered slowest cores first, with `hw.perflevel<N>` from highest N to 0. Checked on an M4 against `cluster-type` in `ioreg -p IODeviceTree`. If the counts don't add up to the CPU count, it falls back to one group.
- Private interfaces are looked up with `dlopen`/`dlsym`, so a macOS update that removes them leaves a `-` rather than a crash. `GPUClockReader` needs the `GPUPH` state count to equal the `voltage-states9` table length; on a chip where they differ, GHZ shows `-`. Only verified on an M4.
- There is deliberately no FPS: `CARenderServerGetFrameCounter` returned 0, so the panel shows `NSScreen.maximumFramesPerSecond` as Hz. TMP is the mean of the SoC `tdie` sensors; no GPU sensor exists on the M4 through this API. Don't relabel either as more than it is.
- Process percentages are divided by core count to match User/System, so they differ from Activity Monitor's per-core figures.
- `CommandRunner` reads the pipes before `waitUntilExit`. `ps` output with full paths can exceed the 64 KB pipe buffer, which would otherwise block `ps` until the timeout.
- `host_processor_info` allocates a buffer on each call that must be `vm_deallocate`d; this app calls it every second, indefinitely.
- `Updater` depends on `release.sh`: the `v1.0.<build>` tag, the `Cpuline.zip` asset name with `Cpuline.app` at its root, and the `org.camerlo.Cpuline` bundle ID. Changing any of them silently stops updates for installed copies.
- App version is derived at runtime from `git rev-list --count HEAD` (see `buildNumber`), not hand-bumped — don't add a manual version constant.
- `run.sh` does `git pull origin HEAD` + `rm -rf .build` before building — don't run it with uncommitted local changes you want to keep.
- The graph is time-based: samples are timestamped when taken, and a 60 fps timer only advances `MetricGraphView.now`. The right edge deliberately shows `now - displayDelay` (2s, over the 1s sample interval) so the newest segment sits between known samples and never reshapes — keep `displayDelay` above the sample interval.
- Performance: no `setShadow` blur in per-frame drawing — CG computes it with a CPU convolution every frame; the neon glow is layered translucent strokes instead. The 60 fps frame timer only runs while the dashboard is visible (`startFrameTimer`/`stopFrameTimerIfIdle`, driven by occlusion), the popover redraws once per sample, the dashboard window is created with `defer: true` and drops its layer contents on close, and the status item image is only rebuilt when its color changes — keep all of these.
- Popover layout: `preferredContentSize = fittingSize` is required or the side margins collapse.
- Updates: running copies only check at launch and daily, so restart the app to see a new release immediately. A bug in the update path can't be fixed by an update; affected copies need a manual install.
- `SMAppService.mainApp.status` can report `.notFound` rather than `.notRegistered` for ad-hoc signed bundles, so don't gate on `== .notRegistered`.
