# libinput smooth scroll Lua plugin

This plugin simulates smooth wheel scrolling by:
- intercepting `REL_WHEEL`/`REL_WHEEL_HI_RES` events (and horizontal equivalents) in `evdev-frame`
- converting wheel steps into virtual distance (`step_size_px`)
- using a libinput timer to release queued distance over time with easing (`animation_time_ms`)
- re-emitting events with `append_frame()` as `REL_*WHEEL*_HI_RES` (+ discrete events when 120 hi-res units are accumulated)

## Callbacks/hooks used (from libinput Lua plugins docs)

- `libinput:register({1})`
- `libinput:connect("new-evdev-device", ...)`
- `libinput:connect("timer-expired", function(now_us) ... end)`
- `device:connect("evdev-frame", function(device, frame, timestamp) ... end)`
- `device:connect("device-removed", function(device) ... end)`
- `device:append_frame(frame)` inside `evdev-frame` or `timer-expired`
- `libinput:timer_set_relative(timeout_us)` for tick scheduling

## Data model

Per-device state:
- `impulses_v`, `impulses_h`: list of active animation impulses
- `backlog_v`, `backlog_h`: remaining virtual distance backlog (px)
- `combo`, `last_input_us`: acceleration state for continuous scrolling
- `residual_v/h`: remainder after converting px -> integer hi-res units
- `detent_carry_v/h`: carry used to emit discrete `REL_WHEEL` after every 120 hi-res units

## Current settings (hardcoded)

Preset selection is now in code via:
- `PRESETS` table
- `ACTIVE_PRESET` (e.g. `"custom"`, `"normal"`, `"aggressive"`, `"precision"`)

Note: `"aggresive"` alias is also accepted in code.

In `smooth_scroll.lua`:
- `step_size_px = 90`
- `pulse_scale = 4.0`
- `animation_time_ms = 360`
- `acceleration_delta_ms = 70`
- `acceleration_scale = 7.0`
- `max_step_scale = 7.0`
- `max_backlog_px = 3600`
- `easing = "easeOutCubic"` (`"linear"` is also supported)
- `enabled = true`
- `reverse_direction = false`
- `enable_horizontal = true`
- `debug = false`

Quick behavior notes:
- `enabled`: `false` means plugin is effectively pass-through (no smoothing/acceleration applied).
- `reverse_direction`: flips both vertical and horizontal scroll direction.
- `enable_horizontal`: when `false`, horizontal wheel events are passed through unchanged (only vertical smoothing remains active).
- `debug`: when `true`, plugin emits extra debug logs (e.g. devices skipped for missing wheel axes).

## Recommended presets

Use these as starting points by editing the `SETTINGS` table in `smooth_scroll.lua`.

| Preset | step_size_px | pulse_scale | animation_time_ms | acceleration_delta_ms | acceleration_scale | acceleration_ramp_k | max_step_scale | max_backlog_px |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Normal | 90 | 2.5 | 320 | 80 | 4.0 | 0.45 | 4.0 | 2600 |
| Aggressive | 90 | 4.0 | 360 | 70 | 7.0 | 0.55 | 7.0 | 3600 |
| Precision | 70 | 1.8 | 260 | 90 | 3.0 | 0.35 | 3.0 | 2000 |

Tips:
- Start with `Normal`, then adjust only one parameter at a time.
- If scrolling feels too jumpy, lower `pulse_scale` and/or `acceleration_scale`.
- If scrolling feels too slow, raise `pulse_scale` before increasing acceleration.

## Acceleration

If `timestamp - last_input_us <= acceleration_delta_ms`, the plugin increments `combo`.
Smooth ramp formula:

`scale = 1 + (target_scale - 1) * (1 - exp(-k * (combo - 1)))`

Where `target_scale = min(acceleration_scale, max_step_scale)`.

## Trackpad vs wheel

The plugin only touches `REL_WHEEL*`/`REL_HWHEEL*` usages, so continuous touchpad-style scrolling (usually not represented by these usages) is passed through.

## Installation / enable

### 1) Copy plugin

```bash
sudo mkdir -p /etc/libinput/plugins
sudo cp smooth_scroll.lua /etc/libinput/plugins/20-smooth-scroll.lua
```

### 2) Enable plugin system

This depends on the compositor/libinput caller. Per libinput docs, plugins are not auto-enabled unless the caller loads the plugin system.

For standalone testing:

```bash
sudo libinput debug-events --enable-plugins --verbose
```

Expected logs:
- `smooth-scroll plugin initialized (API v1)`
- `smooth-scroll active on: <device-name>` for compatible wheel devices
- `smooth-scroll skip (no wheel axes): <device-name>` for devices without wheel axes

### 3) Reload session

Logout/login or reboot so your compositor reloads libinput (if compositor plugin support is available).

## Debug

- Use verbose logs:
  - `sudo libinput debug-events --enable-plugins --verbose`
- If plugin logs do not appear:
  - verify script is under `/etc/libinput/plugins/`
  - verify your compositor supports plugin loading

### When plugin always logs `skip (no wheel axes)`

If `debug-events` shows pointer capability like:

- `cap:p ... scroll-button`

that usually indicates **button scrolling synthesized by libinput core**, not real kernel wheel axes. At plugin (evdev) level there is no `REL_WHEEL`/`REL_WHEEL_HI_RES`, so this plugin correctly skips those devices.

Quick checks for real wheel axes:

```bash
sudo libinput list-devices
```

and/or run `evtest` on the mouse event node:

```bash
sudo evtest /dev/input/eventX
```

If you do not see `REL_WHEEL` or `REL_WHEEL_HI_RES`, this smooth-scroll approach cannot be applied to that device.

## Test plan

### Test 1: single wheel step
- Scroll exactly one detent.
- Expectation: not one large jump; emitted as multiple hi-res chunks over ~360ms.
- Total release should approximate `~90px` (virtual unit), approximately equivalent to ~120 hi-res units before easing/rounding effects.

### Test 2: continuous scrolling (acceleration)
- Scroll multiple detents quickly, keeping interval <= 70ms.
- Expectation: `combo` grows; scale ramps smoothly toward `7x` (no abrupt jump).
- Stop >70ms and scroll again: scale resets close to 1.0.

### Test 3: backlog/coalescing
- Keep scrolling while previous animation is still running.
- Expectation: backlog accumulates and continues smoothly; animation does not hard-reset/jitter.
- Backlog does not exceed `max_backlog_px`.

### Test 4: CPU/overhead
- Observe with `top`/`htop` during continuous scrolling.
- Expectation: low overhead, no CPU spikes, no input lag.

## Important technical limits

- The evdev API has no real pixel unit, only integer wheel units.
- Smooth behavior here is generated by emitting many hi-res wheel events over time, not direct pixel deltas.
- On devices without `REL_*_HI_RES`, smoothness is limited by discrete detent events.

## Next development

We are actively searching for a practical GUI solution to make configuration easier.

Planned direction:
- Provide a lightweight settings UI for editing preset values without manually modifying `smooth_scroll.lua`.
- Include quick profile switching (`custom`, `normal`, `aggressive`, `precision`).
- Add safe apply instructions and basic validation for numeric ranges.
- Keep plugin logic minimal and stable while moving UX convenience to tooling/documentation.
