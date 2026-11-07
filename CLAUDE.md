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
- `ListMetric` — the window's six graphs, as whole-system totals of the list's columns; pure and unit-tested
- `MetricGraphView` — custom NSView drawing one `ListMetric` as a neon line (Catmull-Rom smoothing, glow), auto-scaled from zero
- `CPUPanelView` — the popover's dark panel, all drawn in one view
- `TopStream`/`TopStreamParser`/`TopProcess`/`TopColumn` — run `top -l 0` while the window is on screen and turn its output into samples; parsing is pure and unit-tested. `ProcessTableController` shows them in the window's `NSOutlineView`, under `ProcessCategory` groups, colored green to red by `Heat`
- `Updater` — checks GitHub for the latest release, then downloads, verifies, and swaps in the new app using a detached shell script that waits for the app to quit. `parseRelease` is pure and unit-tested
- `LoginItem` — asks once at launch (remembered in `UserDefaults`) whether to register with `SMAppService.mainApp`; only when installed in an Applications folder
- `DashboardController` — AppKit app delegate; owns the window, the menu bar status item/popover, and the sample timer. Runs as an accessory app (no Dock icon); closing the window keeps it running, quit from the popover

## Gotchas
- `CoreGroup` assumes logical CPUs are numbered slowest cores first, with `hw.perflevel<N>` from highest N to 0. Checked on an M4 against `cluster-type` in `ioreg -p IODeviceTree`. If the counts don't add up to the CPU count, it falls back to one group.
- Private interfaces are looked up with `dlopen`/`dlsym`, so a macOS update that removes them leaves a `-` rather than a crash. `GPUClockReader` needs the `GPUPH` state count to equal the `voltage-states9` table length; on a chip where they differ, GHZ shows `-`. Only verified on an M4.
- There is deliberately no FPS: `CARenderServerGetFrameCounter` returned 0, so the panel shows `NSScreen.maximumFramesPerSecond` as Hz. TMP is the mean of the SoC `tdie` sensors; no GPU sensor exists on the M4 through this API. Don't relabel either as more than it is.
- Process percentages are divided by core count to match User/System, so they differ from Activity Monitor's per-core figures.
- With the window open, the app used ~18–25% of a core with the 20 fps graphs (about the same as the old single 60 fps graph, so the frame rate isn't the main cost) and `top` ~4% on an M4, with a 52 MB footprint. `top` costs about 0.15 s of CPU per sample, so `TopStream` only runs while the window is visible (same occlusion rule as the frame timer). One long-running `-l 0` is about half the cost of `-l 2` per refresh and has no extra lag. Don't use `ps` for the list: its %CPU is a decaying average, not top's. top's first sample has all-zero %CPU and is dropped, so the list fills ~2 s after opening.
- The list's %CPU keeps top's scale (100% = one core), unlike the popover's share of all cores. Deliberate: the list should match `top`.
- IPC needs no root because `top` is setuid: INSTRS and CYCLES are per-sample deltas for every process. CSW, FAULTS and PAGEINS are running totals, so `TopStreamParser` turns them into rates using wall-clock time (top's `-s 2` really takes ~2.09 s). CSW stops at Int32.max (`kernel_task` is there), which shows blank rather than 0. Rates checked against a process's own `getrusage`.
- Don't add a POWER column: it equalled %CPU in every test, while `ri_energy_nj` showed about a 50x difference between normal and background `yes`. `proc_pid_rusage` has that energy figure, P-core time and runnable time, but fails with EPERM for root and other users' processes, so those would be blank for many rows.
- LIMIT comes from `/Library/Logs/DiagnosticReports/*.diag` headers (`Event: cpu usage` or `disk writes`), read once when the list starts. Reports name a program, so every process of that name is marked. If the folder is unreadable the column is just empty.
- The dashboard window shrank to 1186 pt when first ordered front (seen on a 1464 pt Screen Sharing display; cause not found), so `openDashboard` reapplies its frame once.
- `Heat` scores a category against the whole Mac (all cores, all memory), not a process's scale (one core, a quarter of memory), which would keep big categories like macOS permanently red. The cells' neon glow is an `NSShadow` in the attributed string; it is drawn only on each ~2 s refresh, not per frame, and measured ~12% of a core in total with the window open.
- Group items (`ProcessGroupItem`) are kept for the app's lifetime because the outline view remembers collapsed rows by object, across `reloadData`. Replacing them would reopen every category each refresh.
- top cuts COMMAND at 16 characters; `restoreFullName` restores it from `proc_pidpath`, which works for other users' processes. COMMAND must stay last in `-stats` because it can contain spaces. A sample's table closes when its row count matches `Processes: N total`, otherwise on the next header.
- `CommandRunner` reads the pipes before `waitUntilExit`. `ps` output with full paths can exceed the 64 KB pipe buffer, which would otherwise block `ps` until the timeout.
- `host_processor_info` allocates a buffer on each call that must be `vm_deallocate`d; this app calls it every second, indefinitely.
- `Updater` depends on `release.sh`: the `v1.0.<build>` tag, the `Cpuline.zip` asset name with `Cpuline.app` at its root, and the `org.camerlo.Cpuline` bundle ID. Changing any of them silently stops updates for installed copies.
- App version is derived at runtime from `git rev-list --count HEAD` (see `buildNumber`), not hand-bumped — don't add a manual version constant.
- `run.sh` does `git pull origin HEAD` + `rm -rf .build` before building — don't run it with uncommitted local changes you want to keep.
- The graph is time-based: samples are timestamped on arrival, and a 20 fps timer only advances `MetricGraphView.now`. The right edge deliberately shows `now - displayDelay` (3s, over top's ~2.09s interval) so the newest segment sits between known samples and never reshapes — keep `displayDelay` above the sample interval.
- Performance: no `setShadow` blur in per-frame drawing — CG computes it with a CPU convolution every frame; the neon glow is layered translucent strokes instead. The frame timer only runs while the dashboard is visible (`startFrameTimer`/`stopFrameTimerIfIdle`, driven by occlusion, which also stops `TopStream`), the popover redraws once per sample, the dashboard window is created with `defer: true` and drops its layer contents on close, and the status item image is only rebuilt when its color changes — keep all of these.
- Popover layout: `preferredContentSize = fittingSize` is required or the side margins collapse.
- Updates: running copies only check at launch and daily, so restart the app to see a new release immediately. A bug in the update path can't be fixed by an update; affected copies need a manual install.
- `SMAppService.mainApp.status` can report `.notFound` rather than `.notRegistered` for ad-hoc signed bundles, so don't gate on `== .notRegistered`.
