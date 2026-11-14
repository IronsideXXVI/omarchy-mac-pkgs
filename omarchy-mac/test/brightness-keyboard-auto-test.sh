#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

auto="$ROOT/bin/omarchy-brightness-keyboard-auto"
[[ -x $auto ]] || fail "omarchy-brightness-keyboard-auto is executable"
grep -F 'Drive keyboard backlight from the ambient light sensor' "$auto" >/dev/null || fail "command metadata"
pass "the helper and its user unit carry the stock names omarchy-m-test looks for"
[[ -f $ROOT/vendor/systemd/user/omarchy-brightness-keyboard-auto.service ]] || fail "user unit"
[[ -L $ROOT/vendor/systemd/user/graphical-session.target.wants/omarchy-brightness-keyboard-auto.service ]] || fail "unit enabled"
! grep -q -E 'kbd_auto|KBD_LED' "$ROOT/bin/omarchy-mac-brightness-auto" || fail "brightness-auto still drives the keyboard"

t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"; printf '#!/bin/bash\nexit 0\n' >"$t/bin/omarchy-hw-apple-silicon"; chmod +x "$t/bin/omarchy-hw-apple-silicon"
export PATH="$t/bin:$PATH"
map() { OMARCHY_MAC_DT_COMPATIBLE="$t/compatible" OMARCHY_MAC_BRIGHTNESS_DIR="$ROOT/share/omarchy-mac/brightness" "$auto" --map-lux "$1"; }
# The J604's table: macOS's keyboard curve (0.2448 / 0.6916 / 0.6916 / 0.0032 at 0 / 70 / 160 / 300 lux), never 0.
printf 'apple,j604\0apple,t8132\0' >"$t/compatible"
[[ $(map 0) == 24 && $(map 150) == 69 && $(map 230) == 35 && $(map 1000) == 1 ]] ||
  fail "J604 curve" "$(map 0) $(map 150) $(map 230) $(map 1000)"
# A Mac without a table keeps the team's dark/bright line.
printf 'apple,j313\0' >"$t/compatible"
[[ $(map 0) == 100 && $(map 94) == 50 && $(map 400) == 0 ]] || fail "default line" "$(map 0) $(map 94) $(map 400)"
"$auto" --map-lux >/dev/null 2>&1 && fail "map-lux without a value should fail"
pass "lux maps to the model's keyboard curve, or the team's line"

mkdir -p "$t/iio/iio:device0" "$t/leds/kbd_backlight" "$t/bin" "$t/run"
printf 'aop-sensors-als\n' >"$t/iio/iio:device0/name"; echo 0 >"$t/iio/iio:device0/in_illuminance_input"
echo 255 >"$t/leds/kbd_backlight/max_brightness"; echo 0 >"$t/leds/kbd_backlight/brightness"
OMARCHY_IIO_DEVICES_DIR="$t/iio" OMARCHY_LEDS_DIR="$t/leds" "$auto" --available || fail "--available with sensor and LED"
OMARCHY_IIO_DEVICES_DIR="$t/iio" OMARCHY_LEDS_DIR="$t/nothing" "$auto" --available && fail "--available without an LED"
pass "--available answers for the sensor and the LED"

# The loop's tick against stand-ins for brightnessctl and stock omarchy-brightness-keyboard (off keeps the
# level in $XDG_RUNTIME_DIR/omarchy-brightness-keyboard-<device> until restore; the keys step by a tenth).
cat >"$t/bin/brightnessctl" <<'SH'
#!/bin/bash
[[ $1 == -d ]] && { d=$2; shift 2; }
led="$OMARCHY_LEDS_DIR/$d"
case $1 in get) cat "$led/brightness" ;; max) cat "$led/max_brightness" ;; set) echo "$2" >"$led/brightness" ;; esac
SH
cat >"$t/bin/stock-keyboard" <<'SH'
#!/bin/bash
led="$OMARCHY_LEDS_DIR/kbd_backlight"; saved="$XDG_RUNTIME_DIR/omarchy-brightness-keyboard-kbd_backlight"
case $1 in
  off) [[ -s $saved ]] || cat "$led/brightness" >"$saved"; echo 0 >"$led/brightness" ;;
  restore) [[ -f $saved ]] && { cat "$saved" >"$led/brightness"; rm -f "$saved"; } ;;
  down) v=$(( $(<"$led/brightness") - 25 )); (( v < 0 )) && v=0; echo $v >"$led/brightness" ;;
esac
SH
printf '#!/bin/bash\n[[ ${LOCKED:-0} == 1 ]]\n' >"$t/bin/omarchy-hyprland-session-locked"
printf '#!/bin/bash\nexit 1\n' >"$t/bin/omarchy-hw-laptop-closed"
chmod +x "$t/bin/"*
export PATH="$t/bin:$PATH" OMARCHY_LEDS_DIR="$t/leds" XDG_RUNTIME_DIR="$t/run"
printf 'apple,j604\0' >"$t/compatible"
export OMARCHY_MAC_DT_COMPATIBLE="$t/compatible" OMARCHY_MAC_BRIGHTNESS_DIR="$ROOT/share/omarchy-mac/brightness"
eval "$(grep -E '^(DARK_LUX|BRIGHT_LUX|DEADBAND_PERCENT|OVERRIDE_LUX_DELTA|OVERRIDE_LUX_RATIO|EFFECTIVELY_OFF_PERCENT|MANUAL_LEVEL_FILE)=' "$auto")"
for fn in model_curve lux_to_percent read_lux session_locked lid_closed apply_percent left_off tick; do
  eval "$(sed -n "/^$fn()/,/^}/p" "$auto")"
done
KBD_CURVE=$(model_curve)
als_path="$t/iio/iio:device0/in_illuminance_input"; device=kbd_backlight; max=255; last_set=""; paused=0; pause_lux=0
led() { cat "$t/leds/kbd_backlight/brightness"; }
lux() { echo "$1" >"$als_path"; }

tick; (( $(led) == 61 )) || fail "a dark room lights the keys at macOS's 24 %" "got $(led)"
# omarchy-m-test's lock-style blank: stock off, the lock, then the room still wants the keys.
stock-keyboard off; LOCKED=1 tick; (( $(led) == 0 )) || fail "locked: the keys stay blank" "got $(led)"
tick; (( $(led) == 61 )) || fail "keys blanked by the lock light up again" "got $(led)"
stock-keyboard restore; tick; (( $(led) == 61 )) || fail "restore leaves the room's level" "got $(led)"
pass "keys blanked by the lock screen light up again in a room that wants them"
# Off with the keys (stock leaves no record): a choice, kept until the room changes a lot.
for _ in 1 2 3; do stock-keyboard down; tick; done
(( $(led) == 0 )) || fail "the keys step to off" "got $(led)"
tick; tick; (( $(led) == 0 )) || fail "keys turned off by hand stay off" "got $(led)"
lux 150; tick; (( $(led) == 175 )) || fail "a big change in the room resumes (69 % of 255)" "got $(led)"
pass "keys turned off by hand stay off until the room changes enough"
