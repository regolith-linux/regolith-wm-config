#!/bin/bash
# Check regolith-wm-quick-toggles:
# - the three Super keys have an Xresource, a default and a keybinding viewer
#   line, and every key runs a command the helper accepts;
# - the keyboard-backlight keys are bound in the sway session only;
# - the install file ships the partials and the helper;
# - the helper rounds the backlight percentage as documented and rejects
#   unknown commands.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

HELPER=$PWD/scripts/regolith-quick-toggle
COMMON=$PWD/usr/share/regolith/common/config.d/65_quick_toggles
SWAY=$PWD/usr/share/regolith/sway/config.d/66_keyboard_backlight
INSTALL=$PWD/debian/regolith-wm-quick-toggles.install
SUPER=$'\xef\x85\xba'  # U+F17A, the glyph the other viewer lines use
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

# resource, default, viewer action, viewer keys
expected='stay_awake Ctrl+i Toggle Stay Awake i
night_light Ctrl+n Toggle Night Light n
touchpad Ctrl+t Toggle Touchpad t'

while read -r name default action; do
  key=${action##* }
  action=${action% *}
  line="set_from_resource \$wm.binding.$name wm.binding.$name $default"
  grep -qxF "$line" "$COMMON" && pass "$name defaults to $default" \
    || fail "$COMMON lacks: $line"
  grep -qE "^bindsym \\\$mod\+\\\$wm\.binding\.$name exec --no-startup-id regolith-quick-toggle " "$COMMON" \
    && pass "$name is bound to \$mod+\$wm.binding.$name" \
    || fail "no binding for \$mod+\$wm.binding.$name"
  grep -qE "^## [A-Za-z]+ // $action // <$(printf '')><Ctrl> $key ##\$" "$COMMON" \
    && pass "$name has a keybinding viewer line" \
    || fail "no keybinding viewer line for $action"
done <<< "$expected"

if grep -q 'XF86Kbd' "$COMMON"; then
  fail "the common partial binds keyboard-backlight keys (the X11 session leaves them to gnome-settings-daemon)"
else
  pass "the common partial leaves the keyboard-backlight keys alone"
fi
for key in XF86KbdBrightnessUp XF86KbdBrightnessDown XF86KbdLightOnOff; do
  grep -qE "^bindsym --locked $key exec regolith-quick-toggle keyboard-backlight " "$SWAY" \
    && pass "sway binds $key" || fail "sway doesn't bind $key"
done

for f in usr/share/regolith/common/config.d/65_quick_toggles \
         usr/share/regolith/sway/config.d/66_keyboard_backlight; do
  grep -qxF "$f" "$INSTALL" && pass "$f is installed" || fail "$INSTALL lacks $f"
done
grep -qxF "scripts/regolith-quick-toggle usr/bin" "$INSTALL" \
  && pass "the helper is installed" || fail "$INSTALL lacks the helper"
[ -x "$HELPER" ] && pass "the helper is executable" || fail "$HELPER is not executable"

# Every command the partials run, as the helper's argument tuple
commands=$(sed -n 's/.*exec \(--no-startup-id \)\{0,1\}regolith-quick-toggle \(.*\)$/\2/p' "$COMMON" "$SWAY")

PYTHONDONTWRITEBYTECODE=1 python3 - "$HELPER" "$commands" <<'PY' || status=1
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("quick_toggle", sys.argv[1])
spec = importlib.util.spec_from_loader("quick_toggle", loader)
q = importlib.util.module_from_spec(spec)
loader.exec_module(q)
bad = 0
def check(desc, got, want):
    global bad
    if got == want:
        print("ok: " + desc)
    else:
        print("FAIL: %s: got %r, want %r" % (desc, got, want))
        bad = 1
for line in sys.argv[2].splitlines():
    check("the helper accepts '%s'" % line, tuple(line.split()) in q.COMMANDS, True)
check("12.5% is shown as 13%", q.percent(1, 8), 13)
check("0 is shown as 0%", q.percent(0, 3), 0)
check("the maximum is shown as 100%", q.percent(7, 7), 100)
check("2 of 3 is shown as 67%", q.percent(2, 3), 67)
check("unknown commands are refused", q.main(["regolith-quick-toggle", "touchpad", "flip"]), 2)
sys.exit(bad)
PY

exit $status
