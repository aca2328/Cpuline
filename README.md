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
- **Dashboard window**: a smooth, continuously scrolling neon graph (60 s of history, 0–100%) of Total, User, System, each core type, and GPU, with floating labels. Closing the window keeps the app running in the menu bar.

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
