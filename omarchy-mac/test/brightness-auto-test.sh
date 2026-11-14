#!/bin/bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "brightness-auto-test: $*" >&2; exit 1; }

mkdir -p "$t/bin" "$t/iio/iio:device0" "$t/bl/apple-panel-bl" "$t/config" "$t/run" "$t/table"
printf 'apple,j604\0apple,t8132\0apple,arm-platform\0' >"$t/compatible"
echo 600 >"$t/bl/apple-panel-bl/max_brightness"
echo 300 >"$t/bl/apple-panel-bl/brightness"
cat >"$t/bin/brightnessctl" <<EOF
#!/bin/bash
[[ \$1 == -q && \$2 == -d && \$3 == apple-panel-bl && \$4 == set ]] || exit 1
echo "\$5" >"$t/bl/apple-panel-bl/brightness"; echo "\$5" >>"$t/writes"
EOF
printf '#!/bin/bash\nexit 0\n' >"$t/bin/omarchy-hw-apple-silicon"
printf '#!/bin/bash\n[[ -e %s/stock ]]\n' "$t" >"$t/bin/systemctl"
chmod +x "$t/bin/"*
# The model's table with smoothing off, so one read settles.
sed 's/^SMOOTHING=.*/SMOOTHING=1/' "$root/share/omarchy-mac/brightness/apple,j604.conf" >"$t/table/apple,j604.conf"

run() { # lux [args]
  echo "$1" >"$t/iio/iio:device0/in_illuminance_input"
  PATH="$t/bin:$PATH" HOME="$t" XDG_CONFIG_HOME="$t/config" XDG_RUNTIME_DIR="$t/run" \
    OMARCHY_MAC_BRIGHTNESS_ONCE=1 OMARCHY_MAC_BRIGHTNESS_STEP_SLEEP=0 \
    OMARCHY_MAC_BRIGHTNESS_DIR="${table:-$t/table}" OMARCHY_MAC_IIO_ROOT="$t/iio" \
    OMARCHY_MAC_BACKLIGHT_ROOT="$t/bl" OMARCHY_MAC_DT_COMPATIBLE="$t/compatible" \
    bash "$root/bin/omarchy-mac-brightness-auto" "${@:2}"
}
b() { cat "$t/bl/apple-panel-bl/brightness"; }

# The shipped table parses and names this Mac's backlight.
( source "$root/share/omarchy-mac/brightness/apple,j604.conf"; [[ $BACKLIGHT == apple-panel-bl && -n $CURVE ]] ) ||
  fail "shipped table"
# 150 lux is macOS's 223.1 nits, reached in 20 steps (the 1.94 s ramp).
run 150; [[ $(b) == 223 ]] || fail "150 lux -> 223 nits: $(b)"
[[ $(wc -l <"$t/writes") == 20 ]] || fail "ramp steps: $(wc -l <"$t/writes")"
# A dark room: macOS's 139.44 nits.
run 0; [[ $(b) == 139 ]] || fail "0 lux -> 139 nits: $(b)"
# Between points: 75 lux -> 139.44 + (223.11 - 139.44) / 2 = 181.28 nits.
run 75; [[ $(b) == 181 ]] || fail "75 lux -> 181 nits: $(b)"
# A small change in the light (under 5 %) is left alone.
: >"$t/writes"; run 77; [[ ! -s $t/writes ]] || fail "jitter moved the panel: $(b)"
# Bright light: the line carried on to the panel's 600 nits, and held there.
run 1000; [[ $(b) == 600 ]] || fail "1000 lux -> 600 nits: $(b)"
# Covered sensor and back: down to the dark level, then back up.
run 0; [[ $(b) == 139 ]] || fail "covered: $(b)"
run 75; [[ $(b) == 181 ]] || fail "uncovered: $(b)"
# The user sets 362 nits at 75 lux (twice the curve): the curve doubles for every room.
echo 362 >"$t/bl/apple-panel-bl/brightness"; run 75
[[ $(cat "$t/config/omarchy-mac/brightness-auto-scale") == 1.9969 ]] || fail "scale: $(cat "$t/config/omarchy-mac/brightness-auto-scale")"
run 150; [[ $(b) == 446 ]] || fail "scaled 150 lux -> 446 nits: $(b)"
rm "$t/config/omarchy-mac/brightness-auto-scale"
# Off: no further moves; on again resumes.
run 150 off >/dev/null; run 0; [[ $(b) == 446 ]] || fail "off stays off: $(b)"
run 0 on >/dev/null; run 0; [[ $(b) == 139 ]] || fail "on resumes: $(b)"
# Omarchy's own automatic brightness running: step aside.
touch "$t/stock"; run 150; [[ $(b) == 139 ]] || fail "stock service wins: $(b)"; rm "$t/stock"
# A panel that is off (0) is not woken.
echo 0 >"$t/bl/apple-panel-bl/brightness"; run 150; [[ $(b) == 0 ]] || fail "panel off: $(b)"
# A Mac without a table, or without a sensor: nothing happens.
echo 100 >"$t/bl/apple-panel-bl/brightness"; rm -f "$t/run/"*
printf 'apple,j313\0' >"$t/compatible"; run 150; [[ $(b) == 100 ]] || fail "no table: $(b)"
printf 'apple,j604\0' >"$t/compatible"; rm "$t/iio/iio:device0/in_illuminance_input"
PATH="$t/bin:$PATH" HOME="$t" XDG_CONFIG_HOME="$t/config" XDG_RUNTIME_DIR="$t/run" OMARCHY_MAC_BRIGHTNESS_ONCE=1 \
  OMARCHY_MAC_BRIGHTNESS_DIR="$t/table" OMARCHY_MAC_IIO_ROOT="$t/iio" OMARCHY_MAC_BACKLIGHT_ROOT="$t/bl" \
  OMARCHY_MAC_DT_COMPATIBLE="$t/compatible" bash "$root/bin/omarchy-mac-brightness-auto"
[[ $(b) == 100 ]] || fail "no sensor: $(b)"
echo "brightness-auto-test: ok"
