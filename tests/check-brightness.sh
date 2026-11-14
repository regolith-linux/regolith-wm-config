#!/bin/bash
# Check regolith-wm-brightness:
# - both sessions start the brightness service with the step and opt-out
#   resources and bind the brightness keys to regolith-brightness, sway with
#   --locked;
# - the install file ships the i3 partial and both programs;
# - regolith-brightness writes a press into the service's pipe;
# - the service takes presses in the order of their processes, its steps
#   and levels round as documented, and it reads "ddcutil detect --brief"
#   and "getvcp --brief" output as ddcutil 2.2.5 prints it;
# - the built-in panel goes through logind when brightnessctl may not write
#   it.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

CLIENT=$PWD/scripts/regolith-brightness
SERVICE=$PWD/scripts/regolith-brightnessd
I3=$PWD/usr/share/regolith/i3/config.d/65_brightness_keybindings
SWAY=$PWD/usr/share/regolith/sway/config.d/65_media_keybindings
INSTALL=$PWD/debian/regolith-wm-brightness.install
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

expect() {  # file, description, exact line
  grep -qxF "$3" "$1" && pass "$2" || fail "${1##*/} lacks: $3"
}

expect "$I3" "i3 reads the step" \
  'set_from_resource $wm.media.brightness.step wm.media.brightness.step 5'
expect "$I3" "i3 reads the opt-out list" \
  'set_from_resource $wm.media.brightness.ddc.exclude wm.media.brightness.ddc.exclude'
expect "$I3" "i3 starts the service" \
  "exec --no-startup-id \"regolith-brightnessd --step \$wm.media.brightness.step --exclude '\$wm.media.brightness.ddc.exclude'\""
expect "$SWAY" "sway reads the step" \
  'set_from_resource $wm.media.brightness.step wm.media.brightness.step 5'
# sway needs a fallback, and keeps its quotes: "" in "..." is empty for sh
expect "$SWAY" "sway reads the opt-out list" \
  'set_from_resource $wm.media.brightness.ddc.exclude wm.media.brightness.ddc.exclude ""'
expect "$SWAY" "sway starts the service" \
  'exec regolith-brightnessd --step $wm.media.brightness.step --exclude "$wm.media.brightness.ddc.exclude"'
for key in Up:up Down:down; do
  expect "$I3" "i3 binds XF86MonBrightness${key%:*}" \
    "bindsym XF86MonBrightness${key%:*} exec --no-startup-id regolith-brightness ${key#*:}"
  expect "$SWAY" "sway binds XF86MonBrightness${key%:*}" \
    "bindsym --locked XF86MonBrightness${key%:*} exec regolith-brightness ${key#*:}"
done
if grep -q 'lightctl' "$SWAY"; then
  fail "$SWAY still runs lightctl"
else
  pass "sway no longer runs lightctl"
fi

grep -qxF "usr/share/regolith/i3/config.d/65_brightness_keybindings" "$INSTALL" \
  && pass "the i3 partial is installed" || fail "$INSTALL lacks the i3 partial"
for program in regolith-brightness regolith-brightnessd; do
  grep -qxF "scripts/$program usr/bin" "$INSTALL" \
    && pass "$program is installed" || fail "$INSTALL lacks $program"
  [ -x "scripts/$program" ] && pass "$program is executable" \
    || fail "scripts/$program is not executable"
done

RUNTIME=$(mktemp -d)
trap 'rm -rf "$RUNTIME"' EXIT
mkdir -m 0700 "$RUNTIME/regolith-brightness"
mkfifo "$RUNTIME/regolith-brightness/presses"
exec 3<>"$RUNTIME/regolith-brightness/presses"
XDG_RUNTIME_DIR=$RUNTIME sh "$CLIENT" down
read -r parent pid command <&3
if [ "$parent" = $$ ] && [ "$pid" -gt 0 ] && [ "$command" = down ]; then
  pass "regolith-brightness hands the press to the service"
else
  fail "regolith-brightness wrote '$parent $pid $command'"
fi
exec 3<&-
sh "$CLIENT" sideways 2>/dev/null && rc=0 || rc=$?
[ "$rc" = 2 ] && pass "regolith-brightness refuses unknown commands" \
  || fail "regolith-brightness sideways exited with $rc"

PYTHONDONTWRITEBYTECODE=1 python3 - "$SERVICE" <<'PY' || status=1
import importlib.machinery, importlib.util, sys
def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    module = importlib.util.module_from_spec(
        importlib.util.spec_from_loader(name, loader))
    loader.exec_module(module)
    return module
b = load("brightnessd", sys.argv[1])
bad = 0
def check(desc, got, want):
    global bad
    if got == want:
        print("ok: " + desc)
    else:
        print("FAIL: %s: got %r, want %r" % (desc, got, want))
        bad = 1
check("5% of 100 is 5", b.raw_step(5, 100), 5)
check("5% of 50 (2.5) rounds up to 3", b.raw_step(5, 50), 3)
check("5% of 45 (2.25) rounds down to 2", b.raw_step(5, 45), 2)
check("a step is at least 1", b.raw_step(5, 3), 1)
check("100% is the whole range", b.raw_step(100, 255), 255)
check("65 of 200 is shown as 33%", b.percent(65, 200), 33)
check("67 of 200 (33.5%) is shown as 34%", b.percent(67, 200), 34)
check("113 of 255 is shown as 44%", b.percent(113, 255), 44)
check("33% shows the low icon", b.avizo_image(33), "brightness_low")
check("34% shows the medium icon", b.avizo_image(34), "brightness_medium")
check("67% shows the high icon", b.avizo_image(67), "brightness_high")
check("blanks around opt-out entries are dropped",
      b.parse_exclude(" DELL U2415 , ,7MT0186 "), ("DELL U2415", "7MT0186"))
detect = """Display 2
   I2C bus:          /dev/i2c-6
   DRM connector:    card1-HDMI-A-1
   drm_connector_id: 102
   Monitor:          GSM:LG HDR 4K:205NTAB1C123

Invalid display
   I2C bus:          /dev/i2c-2
   DRM connector:    card1-eDP-1
   drm_connector_id: 92
   Monitor:          BOE:NV140FHM-N4A:LAPTOP0001

Display 1
   I2C bus:          /dev/i2c-4
   DRM connector:    card1-DP-1
   drm_connector_id: 101
   Monitor:          DEL:DELL U2415:7MT0186

"""
check("detect output gives the valid displays",
      b.parse_detect(detect),
      [(2, 6, "LG HDR 4K", "205NTAB1C123"), (1, 4, "DELL U2415", "7MT0186")])
check("getvcp output gives the value and the maximum",
      b.parse_getvcp("VCP 10 C 40 100\n"), (40, 100))
check("an unsupported feature gives no value", b.parse_getvcp("VCP 10 ERR\n"), None)
check("the service refuses unknown arguments",
      b.main(["regolith-brightnessd", "--step", "10", "up"]), 2)
arrivals = b.Arrivals()
arrivals.put((30, 31), 1)
arrivals.put((20, 21), -1)
check("presses are taken in the order of their processes",
      [arrivals.get(), arrivals.get()], [-1, 1])
check("a key process is recognised",
      [bool(b.KEY_COMMAND.search(c)) for c in
       (b"/bin/sh /usr/bin/regolith-brightness up",
        b"sh -c regolith-brightness down",
        b"/usr/bin/python3 /usr/bin/regolith-brightnessd --step 5")],
      [True, True, False])
check("brightnessctl -m output gives the device and the level",
      b.parse_panel("intel_backlight,backlight,515,55%,937\n"),
      ("intel_backlight", "backlight", 515, 55))
# The panel: brightnessctl, or logind with brightnessctl's value when the
# backlight isn't writable; nothing without a backlight device.
def panel_step(backlight, writable, direction=1):
    commands, logind = [], []
    def run(argv, timeout):
        commands.append(argv)
        if not backlight:
            return 1, "", "Device '' not found.\n"
        if not writable and "--pretend" not in argv:
            return 1, "", "Can't modify brightness: Permission denied\n"
        return 0, "intel_backlight,backlight,515,55%,937\n", ""
    b.run = run
    panel = b.Panel()
    panel.set_through_logind = lambda *args: logind.append(args) or True
    level = panel.step(b.Press(direction, 5))
    return level, [argv[1:] for argv in commands], logind
check("a writable backlight is stepped by brightnessctl",
      panel_step(True, True),
      (55, [["-m", "--class=backlight", "set", "5%+"]], []))
check("an unwritable backlight is stepped through logind",
      panel_step(True, False, -1),
      (55, [["-m", "--class=backlight", "set", "5%-"],
            ["-m", "--pretend", "--class=backlight", "set", "5%-"]],
       [("intel_backlight", "backlight", 515)]))
check("without a backlight nothing is set",
      panel_step(False, False)[::2], (None, []))
sys.exit(bad)
PY

exit $status
