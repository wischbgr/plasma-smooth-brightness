# smooth-brightness

Smooth, macOS-like screen brightness for KDE Plasma 6 (tested on a Framework 13 Pro
running Kubuntu 26.10, Plasma 6.7, `intel_backlight`).

Out of the box, the brightness keys make the screen jump hard in 5 % steps. This
service takes over the keys, snaps to fixed levels and fades every step smoothly –
the Plasma OSD appears as usual.

## Behavior

- **Levels:** 100 … 10 → 5 → 2 → **0 %** → **off**
  - **0 %** = darkest level, display still on (hardware raw value 1 on the FW13 Pro)
  - **off** = a *new* press of "down" at 0 % (raw value 0, backlight off)
  - Holding the key goes down to 0 % and stops there; "up" from "off" → 0 %
  - Both ends are configurable (`SB_MIN_PERCENT`, `SB_OFF_STEP`, see below)
- **Fade:** 350 ms, ease-out, interpolated perceptually (gamma 2.2)
- **OSD:** shows the target value immediately
- **Holding a key:** every key repeat redirects the running animation to the new
  target – one continuous motion instead of separate jumps
- Tray slider, power management and idle dimming stay in sync

## Installation

```bash
./install.sh
```

The script installs `smooth-brightnessd` to `~/.local/bin/` and the unit to
`~/.config/systemd/user/`, then enables and starts the service
(`graphical-session.target`).

Dependencies: `python3-dbus`, `python3-gi` (preinstalled on Kubuntu).
No root required.

## Uninstall

```bash
./uninstall.sh
```

Stops the service, removes the files and hands the brightness keys back to Plasma's
power management (PowerDevil). A settings override created with
`systemctl --user edit` is kept.

## Settings

Via environment variables in the unit. Persistent and safe across reinstalls with an
override:

```bash
systemctl --user edit smooth-brightness
```

```ini
[Service]
Environment=SB_DURATION_MS=400
```

```bash
systemctl --user restart smooth-brightness
```

| Variable | Default | Meaning |
|---|---|---|
| `SB_STEP` | `5` | Step size in percent |
| `SB_LOW_STEPS` | `2` | Extra levels in percent, comma-separated (e.g. `1,2.5`); empty = none |
| `SB_MIN_PERCENT` | `0` | Lowest level, display still on (`0` = PowerDevil's minimum); levels below it are dropped |
| `SB_OFF_STEP` | `1` | `1` = a new press of "down" at the lowest level switches the backlight off (raw 0); `0` = no off step |
| `SB_BACKLIGHT` | *(empty)* | sysfs backlight used for the off step, e.g. `intel_backlight`, `amdgpu_bl1`; empty = detect automatically |
| `SB_DURATION_MS` | `350` | Duration of one fade; `0` = no animation |
| `SB_FPS` | `120` | Animation frame rate (effectively at most ~100 Hz, see below) |
| `SB_GAMMA` | `2.2` | Perceptual curve of the fade; `1` = linear |
| `SB_DEBUG` | `0` | `1` = verbose log |

## Usage & diagnostics

```bash
systemctl --user status smooth-brightness
journalctl --user -u smooth-brightness -f       # log
smooth-brightnessd up | down                    # trigger one step (test)
smooth-brightnessd --restore                    # hand the keys back to PowerDevil
```

The shortcuts appear in *System Settings → Keyboard → Shortcuts* under
"Smooth Screen Brightness". They are pinned to the brightness keys whenever the
service starts; changing them there does not survive a service restart.

Shift + brightness key (1 % fine step) stays with PowerDevil and is not animated.

## Other laptops

Everything except the off step goes through standard Plasma/systemd interfaces
(kglobalaccel, PowerDevil's `org.kde.ScreenBrightness`, the Plasma OSD, logind), so
it should work on most laptops with **Plasma 6** recent enough to provide
`org.kde.ScreenBrightness` (roughly 6.2+). Only the FW13 Pro has been tested.

After installing on another machine, check `journalctl --user -u smooth-brightness`
and step all the way down once. The daemon logs what it finds:

| Log message | Meaning / what to do |
|---|---|
| `Backlight device for the off step: … (only device)` | Normal case |
| `… (brightness matches PowerDevil best …; will confirm on the next step)` followed by `… (changed together with PowerDevil)` | Several sysfs backlights (e.g. hybrid graphics): the daemon picks the one whose brightness matches PowerDevil, then confirms it by watching which device actually changes. Override with `SB_BACKLIGHT` |
| `Off step unavailable (…)` | PowerDevil doesn't drive a sysfs backlight (or none exists); fades work, there is just no off step |
| `WARNING: … does not stay at raw value 0` | The driver doesn't allow switching the backlight off → `SB_OFF_STEP=0` |
| `WARNING: … has only N hardware levels` / `PowerDevil offers only N brightness levels` | Coarse backlight (common with `acpi_video`): fades visibly step |
| `WARNING: … these levels map to the same hardware value: 0/2 %` | Levels too close for the hardware → adjust `SB_LOW_STEPS` / `SB_MIN_PERCENT` |

Tuning the bottom end for a different panel:

- Display already black at the lowest level → raise it, e.g. `SB_MIN_PERCENT=1`
- Lowest level is fine but you don't want an off step → `SB_OFF_STEP=0`
- Switching back on restores the raw value the panel had right before switching off,
  so it doesn't depend on how PowerDevil maps its minimum to hardware values.

Not covered: brightness keys handled by the laptop firmware itself (no key event
reaches Plasma – like the keyboard backlight below), and external monitors (only the
internal display is animated).

## Technical approaches

### Catching the keys

| Approach | Result |
|---|---|
| `.desktop` shortcut launches a script per key press | ❌ one process start per press, presses queue up, no snapping |
| Reading input devices directly (evdev) | ❌ needs the `input` group, PowerDevil keeps reacting in parallel |
| **Registering our own global shortcuts via kglobalaccel (DBus)** | ✅ **chosen** – one long-running process receives `globalShortcutPressed`/`Repeated`; PowerDevil's shortcut is disabled meanwhile |

### Writing the brightness

| Approach | Result |
|---|---|
| `brightnessctl` / sysfs directly | ❌ PowerDevil doesn't notice and drifts out of sync with the real brightness |
| Whole animation as raw values via logind, PowerDevil synced at the end | ❌ **flickers** – PowerDevil's root helper animates by itself from its last known value and jumps back on sync (`9600 → 16321 → 9601`) |
| **Set every frame through PowerDevil** (`org.kde.ScreenBrightness.Display.SetBrightnessWithContext`, flag *SuppressIndicator*) | ✅ **chosen** – everything stays in sync, no flicker |

Limits of the chosen approach: PowerDevil's root helper manages about 100 hardware
changes per second (measured: 60 Hz → 56/s, 120 Hz → 97/s, 240 Hz → 113/s), and
PowerDevil works in 10 000 steps. Towards the end of a fade the value therefore no
longer changes on every frame, and at the bottom (2 % → 0 %) the fade visibly ends
earlier.

### The bottom end / switching off

On this panel: **raw value 0 = backlight off**, **raw value 1 = darkest level with
the display on**. PowerDevil's value 0 writes raw value 1 by itself.

| Approach | Result |
|---|---|
| Minimum 1 %, another press → raw value 0 | ❌ PowerDevil's 0 (= raw 1) is darker than 1 % – a wasted level |
| 0 % = raw value 0, no "off" level | ❌ raw value 0 already is off |
| Switching off via DPMS ("Turn Off Screen") | ❌ unnecessary, raw value 0 already turns the backlight off |
| **0 % = PowerDevil 0 (raw 1); a new press → raw value 0 directly via logind** | ✅ **chosen** – PowerDevil is at 0 anyway, no conflict |

Raw value 0 is written via `org.freedesktop.login1.Session.SetBrightness` (works
without root for the active session). Because PowerDevil's helper may asynchronously
write its minimum again afterwards, the service holds the value at 0 for ~1 s after
switching off, and also reacts to later PowerDevil changes to its minimum. An "off"
press during a running fade is queued until the fade ends: jumping PowerDevil
straight to its minimum would make its helper start a slow fade of its own, which
ends above 0 after the backlight was switched off.

## Architecture

```
Brightness key
   │  KWin → kglobalaccel
   ▼
smooth-brightnessd  (systemd --user, Python, GLib main loop)
   ├─ compute level (0, 2, 5, 10 … 100 %)
   ├─ OSD:        org.kde.plasmashell  /org/kde/osdService  brightnessChanged(%)
   ├─ animation:  org.kde.ScreenBrightness  …/display0  SetBrightnessWithContext
   │              (per frame, without PowerDevil's OSD)
   └─ off/on:     org.freedesktop.login1  Session.SetBrightness(backlight, 0|1)
```

Robustness:

- Brightness changed by someone else (slider, idle dimming) during the animation →
  the animation is cancelled
- kglobalaccel or PowerDevil restarts → shortcuts or display are re-acquired
- The service stops or crashes → `ExecStopPost=… --restore` hands the keys back to
  PowerDevil; `Restart=on-failure` restarts it

## Files

| File | Purpose |
|---|---|
| `smooth-brightnessd` | The daemon |
| `smooth-brightness.service` | systemd user unit incl. default settings |
| `install.sh` | Installation |
| `uninstall.sh` | Removal, hands the keys back to PowerDevil |
