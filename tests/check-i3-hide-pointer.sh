#!/bin/bash
# Check regolith-i3-hide-pointer and i3's 86_unclutter:
# - the partial starts the helper with exec_always, and wm.program.unclutter
#   once, with exec, and the package installs the helper;
# - the helper reads the hide_cursor Xresources as the sway session does;
# - with an X server at hand (Xvfb), the helper keeps running, a second
#   instance takes over from the first, and with xrdb, the helper exits when
#   wm.program.unclutter is set or there is nothing to hide.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

HELPER=$PWD/scripts/regolith-i3-hide-pointer
PARTIAL=$PWD/usr/share/regolith/i3/config.d/86_unclutter
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

one_line() {  # description, exact line of the partial
  local n
  n=$(grep -cxF "$2" "$PARTIAL" || true)
  if [ "$n" = 1 ]; then pass "$1"; else fail "$1: expected the line '$2' once, found it $n times"; fi
}
one_line "one exec_always line" 'exec_always --no-startup-id regolith-i3-hide-pointer'
# shellcheck disable=SC2016 # i3 variables, not shell ones
one_line "wm.program.unclutter defaults to true" 'set_from_resource $wm.program.unclutter wm.program.unclutter true'
# shellcheck disable=SC2016
one_line "one exec line for wm.program.unclutter" 'exec --no-startup-id $wm.program.unclutter'
if grep -qx 'scripts/regolith-i3-hide-pointer usr/bin' debian/regolith-i3-unclutter.install; then
  pass "regolith-i3-unclutter installs the helper"
else
  fail "debian/regolith-i3-unclutter.install doesn't install the helper"
fi

PYTHONDONTWRITEBYTECODE=1 python3 - "$HELPER" <<'PY' || status=1
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("hide", sys.argv[1])
spec = importlib.util.spec_from_loader("hide", loader)
h = importlib.util.module_from_spec(spec)
loader.exec_module(h)
bad = 0
def check(desc, got, want):
    global bad
    if got == want:
        print(f"ok: {desc}")
    else:
        print(f"FAIL: {desc}: got {got!r}, want {want!r}")
        bad = 1
for value, want in (("2000", 2000), ("+2000", 2000), ("0002000", 2000), ("100", 100),
                    ("99", 100), ("1", 100), ("+1", 100), ("-3", 100),
                    ("-2147483648", 100), ("2147483647", 2147483647),
                    ("0", None), ("-0", None), ("+0", None), ("000", None),
                    ("1.5", None), ("2s", None), ("abc", None), ("1e3", None),
                    ("+", None), ("--1", None), ("0x10", None), (" 5", 100),
                    (" 2000", 2000), ("2000 ", 2000), ("\t2000\t", 2000),
                    ("1_000", None), ("١٢٣", None), ("１２３", None)):
    check(f"timeout {value!r}", h.parse_timeout(value), want)
for value in ("1", "yes", "on", "true", "enable", "enabled", "active", "ENABLED", "aCtIvE",
              " on", "on ", "\ton"):
    check(f"typing {value!r} is on", h.parse_typing(value), True)
for value in ("0", "2", "no", "off", "disable", "toggle", "", " ", "truthy", "yesplease",
              "o_n", "o n", "１", "١"):
    check(f"typing {value!r} is off", h.parse_typing(value), False)
def settings(**resources):
    return h.settings(lambda name: resources.get(name.rpartition(".")[2]))
check("defaults", settings(), (5000, True))
check("the misspelled timout", settings(timout="2000"), (2000, True))
check("timeout wins over timout", settings(timeout="3000", timout="2000"), (3000, True))
check("an unusable timeout still wins", settings(timeout="abc", timout="2000"), (None, True))
check("timeout 0 wins", settings(timeout="0", timout="2000"), (None, True))
check("typing off", settings(show_when_typing="disable"), (5000, False))
import ctypes
if ctypes.sizeof(ctypes.c_long) == 8:
    check("XGenericEventCookie size", ctypes.sizeof(h.XGenericEventCookie), 56)
    check("XPropertyEvent time offset", h.XPropertyEvent.time.offset, 48)
    check("XEvent size", ctypes.sizeof(h.XEvent), 192)
sys.exit(bad)
PY

if command -v Xvfb > /dev/null; then
  work=$(mktemp -d)
  first='' second='' third=''
  exec 3> "$work/display"
  Xvfb -displayfd 3 -noreset -nolisten tcp > "$work/xvfb.log" 2>&1 &
  xvfb=$!
  exec 3>&-
  trap 'kill $xvfb $first $second $third 2> /dev/null; rm -rf "$work"' EXIT
  for _ in $(seq 50); do [ -s "$work/display" ] && break; sleep 0.1; done
  DISPLAY=:$(head -n 1 "$work/display")
  export DISPLAY
  "$HELPER" 2> "$work/first.err" &
  first=$!
  sleep 1
  if kill -0 "$first" 2> /dev/null; then pass "the helper keeps running"
  else fail "the helper exited: $(cat "$work/first.err")"; fi
  "$HELPER" 2> "$work/second.err" &
  second=$!
  sleep 1.5
  if ! kill -0 "$first" 2> /dev/null && kill -0 "$second" 2> /dev/null; then
    pass "a second instance takes over from the first"
  else
    fail "takeover: first alive=$(kill -0 "$first" 2> /dev/null && echo y || echo n)," \
         "second alive=$(kill -0 "$second" 2> /dev/null && echo y || echo n): $(cat "$work/second.err")"
  fi
  if command -v xrdb > /dev/null; then
    exits() {  # desc, resources: the helper exits 0 within 2 s and the running one too
      printf '%s\n' "$2" | xrdb -load -
      "$HELPER" 2> "$work/third.err" &
      third=$!
      for _ in $(seq 20); do kill -0 "$third" 2> /dev/null || break; sleep 0.1; done
      if kill -0 "$third" 2> /dev/null; then
        fail "$1: the helper still runs"
      elif wait "$third"; then
        if kill -0 "$second" 2> /dev/null; then fail "$1: the previous instance still runs"
        else pass "$1: the helper exits"; fi
      else
        fail "$1: the helper failed: $(cat "$work/third.err")"
      fi
      third=''
    }
    exits "wm.program.unclutter set" 'wm.program.unclutter: /usr/bin/unclutter -b'
    exits "no idle or typing hiding" 'wm.hide_cursor.timeout: 0
wm.hide_cursor.show_when_typing: disable'
  else
    echo "skip: no xrdb, the early exits are not checked"
  fi
else
  echo "skip: no Xvfb, the X server checks are not run"
fi

exit $status
