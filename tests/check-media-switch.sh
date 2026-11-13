#!/bin/bash
# Check regolith-wm-media-switch:
# - the three Super keys have an Xresource, a default and a keybinding viewer
#   line, and with the Shift media keys run a command the helper accepts;
# - the i3 partial binds the player keys and starts playerctld, but leaves the
#   volume keys and the Media key to gnome-settings-daemon;
# - the install file ships the partials and the helper;
# - the helper steps with wrap-around, tells monitors from inputs, and rejects
#   unknown commands.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

HELPER=$PWD/scripts/regolith-media-switch
COMMON=$PWD/usr/share/regolith/common/config.d/65_media_switch
I3=$PWD/usr/share/regolith/i3/config.d/65_media_keybindings
INSTALL=$PWD/debian/regolith-wm-media-switch.install
SUPER=$'\xef\x85\xba'  # U+F17A, the glyph the other viewer lines use
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

# resource, default, viewer action, viewer keys
expected="audio_output Ctrl+o Switch Audio Output <Ctrl> o
audio_input Ctrl+Shift+o Switch Audio Input <Ctrl><Shift> o
media_player Ctrl+p Switch Media Player <Ctrl> p"

while read -r name default action; do
  keys="<${action#*<}"
  action=${action%% <*}
  line="set_from_resource \$wm.binding.$name wm.binding.$name $default"
  grep -qxF "$line" "$COMMON" && pass "$name defaults to $default" \
    || fail "$COMMON lacks: $line"
  grep -qE "^bindsym \\\$mod\+\\\$wm\.binding\.$name exec --no-startup-id regolith-media-switch " "$COMMON" \
    && pass "$name is bound to \$mod+\$wm.binding.$name" \
    || fail "no binding for \$mod+\$wm.binding.$name"
  grep -qxF "## Modify // $action // <$SUPER>$keys ##" "$COMMON" \
    && pass "$name has a keybinding viewer line" \
    || fail "no keybinding viewer line for $action"
done <<< "$expected"

for binding in "Shift+XF86AudioMute output" "Shift+XF86AudioMicMute input" \
               "Shift+XF86AudioPlay player" "Shift+XF86AudioPause player"; do
  grep -qxF "bindsym ${binding% *} exec --no-startup-id regolith-media-switch ${binding#* }" "$COMMON" \
    && pass "${binding% *} switches the ${binding#* }" \
    || fail "${binding% *} doesn't switch the ${binding#* }"
done

for binding in "bindcode 172 exec --no-startup-id playerctl play-pause" \
               "bindcode 208 exec --no-startup-id playerctl play" \
               "bindcode 209 exec --no-startup-id playerctl pause" \
               "bindsym XF86AudioNext exec --no-startup-id playerctl next" \
               "bindsym XF86AudioPrev exec --no-startup-id playerctl previous" \
               "bindsym XF86AudioStop exec --no-startup-id playerctl stop" \
               "bindsym XF86AudioRewind exec --no-startup-id playerctl position 10-" \
               "bindsym XF86AudioForward exec --no-startup-id playerctl position 45+" \
               "exec --no-startup-id playerctld daemon"; do
  grep -qxF "$binding" "$I3" && pass "i3: $binding" || fail "$I3 lacks: $binding"
done
if grep -qE 'XF86Audio(RaiseVolume|LowerVolume|Mute|MicMute|Media)' "$I3"; then
  fail "the i3 partial binds keys gnome-settings-daemon handles"
else
  pass "the i3 partial leaves the volume keys and the Media key alone"
fi

for f in usr/share/regolith/common/config.d/65_media_switch \
         usr/share/regolith/i3/config.d/65_media_keybindings; do
  grep -qxF "$f" "$INSTALL" && pass "$f is installed" || fail "$INSTALL lacks $f"
done
grep -qxF "scripts/regolith-media-switch usr/bin" "$INSTALL" \
  && pass "the helper is installed" || fail "$INSTALL lacks the helper"
[ -x "$HELPER" ] && pass "the helper is executable" || fail "$HELPER is not executable"

grep -qxF "exec --no-startup-id regolith-media-switch track" "$COMMON" \
  && pass "the session starts the player tracker" \
  || fail "$COMMON doesn't start the player tracker"

# Every command the keys run, as the helper's argument
commands=$(sed -n 's/^bindsym .* exec --no-startup-id regolith-media-switch \(.*\)$/\1/p' "$COMMON" | sort -u)

PYTHONDONTWRITEBYTECODE=1 python3 - "$HELPER" "$commands" <<'PY' || status=1
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("media_switch", sys.argv[1])
spec = importlib.util.spec_from_loader("media_switch", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
bad = 0
def check(desc, got, want):
    global bad
    if got == want:
        print("ok: " + desc)
    else:
        print("FAIL: %s: got %r, want %r" % (desc, got, want))
        bad = 1
for line in sys.argv[2].splitlines():
    check("the helper accepts '%s'" % line, line in m.COMMANDS, True)
check("a step goes to the next choice", m.step(["a", "b", "c"], "a"), "b")
check("a step wraps around", m.step(["a", "b", "c"], "c"), "a")
check("a step from an unlisted choice goes to the first", m.step(["a", "b"], "x"), "a")
check("a step without a current choice goes to the first", m.step(["a", "b"], None), "a")
check("a single choice stays", m.step(["a"], "a"), "a")
check("a monitor is not an input",
      m.is_monitor({"name": "s.monitor", "monitor_source": "s",
                    "properties": {"device.class": "monitor",
                                   "media.class": "Audio/Sink"}}), True)
check("a virtual input is an input",
      m.is_monitor({"name": "mic", "monitor_source": "",
                    "properties": {"media.class": "Audio/Source/Virtual"}}), False)
check("unknown commands are refused", m.main(["regolith-media-switch", "volume"]), 2)
sys.exit(bad)
PY

exit $status
