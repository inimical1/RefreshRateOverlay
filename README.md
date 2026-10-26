# Refresh Rate + FPS Overlays

Two always-on-top macOS overlays plus a menu bar control panel:

- **Refresh Rate** pill — live measured display refresh rate (from the display link, not from System Settings)
- **FPS Meter** pill — live frames per second reaching the display, with a small sparkline

Both are draggable, stay above normal windows on every Space (including full-screen apps), and remember their positions.

## Toggles (menu bar, next to Wi-Fi / Control Center)

Click the **speedometer** icon in the menu bar:

| Item | What it does |
| --- | --- |
| **FPS Meter** | Show/hide the FPS overlay (checkmark = visible) |
| **Refresh Rate** | Show/hide the refresh-rate overlay |
| **Reset Positions** | Puts both overlays back in the top-right corner and shows them |
| **Launch App with FPS HUD…** | Relaunches a Metal app with Apple's built-in per-app FPS HUD (`MTL_HUD_ENABLED=1`) |
| **Quit Refresh Rate** | Quits everything |

Global hotkeys work from any app, no menu needed:

- `⌥⌘F` — toggle FPS meter
- `⌥⌘R` — toggle refresh-rate meter

Right-clicking either pill also gives you the toggles and Quit.

## Refresh rate vs FPS

- **Refresh rate** is a property of the display mode: how many times per second the panel scans out a frame.
- **FPS** is how many frames actually get delivered to the display each second. It's capped by the refresh rate and drops when the compositor misses a deadline.

These overlays measure delivery at the display link, which is the honest number without screen-recording permission or injecting into another process. For *per-app* FPS (a game rendering at 47 fps on a 60 Hz panel), macOS only exposes that through Metal's HUD — hence the menu item above, which relaunches a chosen app with the HUD enabled.

Note: this MacBook's built-in display only offers a 60 Hz mode, so both meters will read ~60 here. On a 120/144 Hz external display, drag the pills onto it and the numbers follow.

## Build / run

```bash
./build.sh
```

Compiles `main.swift`, builds `~/Applications/RefreshRate.app`, ad-hoc signs it, restarts and opens it.

To start at login: System Settings → General → Login Items → **+** → `~/Applications/RefreshRate.app`.

## Debug

```bash
pkill -x RefreshRate
RRO_DEBUG=1 ~/Applications/RefreshRate.app/Contents/MacOS/RefreshRate
```

Logs the sampled values and frame counts once a second for both meters.

## Files

- `main.swift` — the whole app
- `Info.plist` — bundle metadata
- `build.sh` — build + install + launch
