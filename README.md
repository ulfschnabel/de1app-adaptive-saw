# adaptive_saw — Adaptive Stop-At-Weight for the Decent Espresso DE1

A plugin for the [Decent Espresso DE1 app](https://github.com/decentespresso/de1app) that makes stop-at-weight self-correcting.

## The problem

The DE1's built-in SAW (Stop At Weight) uses a fixed offset (`stop_weight_before_seconds`) to stop the pump early, accounting for in-flight water that keeps dripping after the pump stops.  That offset is global, in seconds, and doesn't adapt — so if your profile typically overshoots by 2 g you have to dial in the offset by hand and redo it whenever you switch profiles or beans.

## What this plugin does

After each espresso shot it computes the overshoot (actual − target) and updates a **per-profile learned gram offset** using an exponential moving average (EMA).  Before the next shot it injects that offset directly into the SAW engine so the pump stops at exactly the right moment for that profile.

- Works with **all profile types** (`settings_2a`, `settings_2b`, `settings_2c` / advanced)
- Works with **all skins** (DSx2, Streamline, default, …)
- Offsets are stored **per profile title**, so different beans and grind settings converge independently
- Converges in **3–5 shots** per profile

### Trade-off

The plugin **zeros `stop_weight_before_seconds`** on load and takes full ownership of the stop-early offset in grams.  The hardware-latency terms (`sensor_lag`, `lag_time_estimation`, `_lag_time_de1`) remain active — only the user-tuneable seconds offset is replaced.

If you ever disable this plugin, manually restore `stop_weight_before_seconds` to ~0.15 in the app settings.

## Installation

### Via the GitHub plugin installer (recommended)

Install [de1app_plugin_github](https://github.com/ebengoechea/de1app_plugin_github) first, then point it at this repo:  `ulfschnabel/de1app-adaptive-saw`.

Once installed the first time, the GitHub installer will keep it up to date automatically.

### Manually on the tablet

```sh
cd /storage/de1/de1plus/plugins
mkdir adaptive_saw
cd adaptive_saw
# Download plugin.tcl from the latest release
curl -L https://github.com/ulfschnabel/de1app-adaptive-saw/releases/latest/download/plugin.tcl -o plugin.tcl
```

Then in the DE1 app: **Settings → Extensions** → enable **Adaptive SAW** → restart the app.

### Over ADB from a computer

```sh
adb shell mkdir /storage/de1/de1plus/plugins/adaptive_saw
adb push plugin.tcl /storage/de1/de1plus/plugins/adaptive_saw/
```

## Configuration

All settings are stored in the plugin's settings file and can be changed by editing `plugin.tcl` defaults or via a future settings page.

| Setting | Default | Description |
|---|---|---|
| `alpha` | `0.4` | EMA learning rate (0–1). Higher = adapts faster but noisier. |
| `max_offset` | `8.0` | Maximum gram offset (safety clamp). |

Alpha of 0.4 gives roughly:
- Shot 1: offset = 0 g (cold start)
- Shot 2: offset ≈ 40% of first overshoot
- Shot 3–4: within ±0.3 g of target for stable profiles

## How it works

```
stop_early_grams = _early_by_grams + flow_now × (sensor_lag + lag_estimation + 0.1s)
```

The plugin sets `_early_by_grams` (previously always 0) to the learned per-profile value.  The time-based hardware-latency terms are unchanged.

After each shot:
```
overshoot     = actual_final_weight − target_weight
new_offset    = old_offset + alpha × overshoot
new_offset    = clamp(new_offset, 0, max_offset)
```

## Log output

Every shot produces a log line you can see in `log.txt`:

```
adaptive_saw: 'My Profile'  actual=38.4g  target=36.0g  overshoot=+2.40g  offset 0.00->0.96g
adaptive_saw: 'My Profile'  actual=36.8g  target=36.0g  overshoot=+0.80g  offset 0.96->1.28g
adaptive_saw: 'My Profile'  actual=36.1g  target=36.0g  overshoot=+0.10g  offset 1.28->1.32g
```

## License

MIT
