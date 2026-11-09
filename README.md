# Cpuline

Native macOS menu bar app that tracks CPU usage on your Mac, with GPU, load, and uptime alongside.

## Features

- **Menu bar app**: starts as a menu bar icon only (no Dock icon). The icon is green below 50% total CPU, orange below 85%, red above, and gray before the first sample.
- **Popover**: click the icon for a dark status panel:
  - **CPU**: 60 seconds of stacked User and System bars, with current percentages.
  - **Cores**: one ring per core, plus the average for each core type (Efficiency and Performance on Apple silicon).
  - **Processes**: the three busiest, as a percentage of all cores. Helpers count toward their app, and OS binaries are grouped as "macOS".
  - **GPU**: display refresh rate, then rings for usage, memory, temperature, and clock.
  - **Load and uptime**: the 1, 5, and 15 minute load averages, and time since boot.
- **Dashboard window**: a detailed process list like the `top` command, under six small scrolling neon graphs (60 s of history) of the list's totals: %CPU, IPC, MEM, CSW/S, FLT/S, and PIN/S. Each has its own scale from zero, shown beside it, and fills only while the window is on screen, with a gap for any time it wasn't. MEM adds up the column, which counts compressed memory, so it can exceed the physical memory in use. CSW/S leaves out `kernel_task`, as in the list. The menu bar popover still shows User, System, each core type, and GPU. Closing the window keeps the app running in the menu bar.

## Process list

The list shows every process, refreshed about every 2 seconds, grouped by category and sorted by %CPU. Categories start collapsed, showing their totals; click a triangle to open one. The list remembers which categories are open, even after the app restarts. Click a column header to sort by it, and click again to reverse.

Every row is colored on one neon scale, from dim green through bright yellow to red. A process is full red at one full core of CPU or a quarter of the Mac's memory, whichever is closer, and its row is tinted more as it gets there. A category's row uses the same scale for its share of the whole Mac: all cores, or all of its memory. Hover over a column title or a graph for a description.

| Column | Meaning |
|---|---|
| CATEGORY | Apps, VMs, Services, CLI (command line tools), macOS, or Other, worked out from where the executable is |
| PID, PPID | Process ID and its parent's |
| COMMAND | Executable name |
| %CPU | As in `top`: 100% is one full core, so it can exceed 100% |
| IPC | Instructions per cycle over the last sample. Very low usually means stalled, often on memory. Treat it as a rough signal: the same program can vary a lot between runs |
| TIME | CPU time used: `h:m:s`, or `m:s.hundredths` when shorter |
| #TH | Threads, with the number running after a slash when any are |
| #PORTS | Mach ports |
| MEM, CMPRS | Memory use and compressed memory, as `top` reports them |
| STATE | Running, sleeping, stuck, and so on |
| IDLEW | Times the process woke the CPU from idle |
| CSW/S | Context switches per second. Blank for `kernel_task`, whose total has reached `top`'s maximum |
| FLT/S, PIN/S | Page faults and page-ins per second. Sustained page-ins point to memory pressure |
| LIMIT | `CPU` or `Disk` if macOS reported a program of this name over its CPU or disk write limit in the last 7 days, read when the list starts. The full reports are in Console, under Diagnostic Reports |
| USER | Owner |

There is deliberately no POWER column. In `top` it matched %CPU in every test here, although a background process at about 100% used about 50 times less energy than a normal one. The values come from `/usr/bin/top`, which runs only while the window is on screen and appears in the list itself. The popover's process percentages are a share of all cores, so a process at 90% here reads 9% there on a 10-core Mac.

## What the GPU values mean

- **Hz**: the display's maximum refresh rate, not a measured frame rate. macOS has no working source for system-wide FPS.
- **MEM**: GPU memory in use, as a share of system memory.
- **TMP**: average SoC die temperature. Apple silicon exposes no GPU-specific sensor this way.
- **GHZ**: average clock over the last second, counting time powered off as 0 GHz. The ring is scaled to the GPU's top clock.

TMP and GHZ use private system interfaces (`IOHIDEventSystemClient` and `libIOReport`), looked up at runtime. Where they aren't available, as on Intel Macs, the value shows `-`. No `sudo` is needed.

## Install

Build a signed universal `.app` bundle (with icon) and copy it to Applications:

```sh
./bundle.sh
cp -R .build/Cpuline.app /Applications/
```

The build number shown in the app is the git commit count at bundle time. Re-run `./bundle.sh` after pulling new commits. It runs on macOS 13 or later, on Apple silicon and Intel Macs.

## Run from source

```sh
swift run Cpuline
```

## Open at login

The first time Cpuline runs from an Applications folder, it asks whether to open at login. It only asks once; to change your answer later, use System Settings › General › Login Items.

## Updates

Cpuline checks the `aca2328/Cpuline` GitHub repository for a new release at launch and once a day. When one exists, the menu bar popover shows an **Update** button: click it to download the release, verify it, replace the app, and relaunch. The app needs write access to the folder it's installed in; otherwise the button opens the release page instead. `./release.sh` publishes a release.

## License

MIT, see [LICENSE](LICENSE).
