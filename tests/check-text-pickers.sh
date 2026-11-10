#!/bin/bash
# Check regolith-wm-text-pickers:
# - the four Super keys have an Xresource, a default and a keybinding viewer
#   line, run the intended helper command and pass the look's ilia stylesheet;
# - the install file ships the partial and both helpers;
# - with a stand-in ilia and no display, the clipboard history keeps the newest
#   entries first without duplicates, honours the size, picks, deletes and
#   clears the chosen rows only, leaves nothing behind on disk for entries it
#   dropped, and the emoji picker lists every fully-qualified emoji and copies
#   exactly the chosen one.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

SRC=$PWD
PARTIAL=$SRC/usr/share/regolith/common/config.d/83_text_pickers
INSTALL=$SRC/debian/regolith-wm-text-pickers.install
CLIPBOARD=$SRC/scripts/regolith-clipboard
EMOJI=$SRC/scripts/regolith-emoji
EMOJI_TEST=/usr/share/unicode/emoji/emoji-test.txt
SUPER=$'\xef\x85\xba'  # U+F17A, the glyph the other viewer lines use
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

# resource | default | command | viewer action | viewer keys
expected="clipboard.history|Ctrl+v|regolith-clipboard pick|Clipboard History|<$SUPER><Ctrl> v
clipboard.delete|Ctrl+Shift+v|regolith-clipboard delete|Delete from Clipboard History|<$SUPER><Ctrl><Shift> v
clipboard.clear|Ctrl+Shift+Delete|regolith-clipboard clear|Clear Clipboard History|<$SUPER><Ctrl><Shift> Delete
emoji|Ctrl+e|regolith-emoji|Emoji Picker|<$SUPER><Ctrl> e"

while IFS='|' read -r res default command action keys; do
  line="set_from_resource \$wm.binding.$res wm.binding.$res $default"
  grep -qxF "$line" "$PARTIAL" && pass "wm.binding.$res defaults to $default" \
    || fail "$PARTIAL lacks: $line"
  line="bindsym \$mod+\$wm.binding.$res exec --no-startup-id $command -t \$wm.text_pickers.ilia_stylesheet"
  grep -qxF "$line" "$PARTIAL" && pass "\$mod+\$wm.binding.$res runs '$command'" \
    || fail "$PARTIAL lacks: $line"
  grep -qxF "## Launch // $action // $keys ##" "$PARTIAL" \
    && pass "'$action' has a keybinding viewer line" \
    || fail "no keybinding viewer line '## Launch // $action // $keys ##'"
done <<< "$expected"

grep -qxF 'set_from_resource $wm.text_pickers.ilia_stylesheet ilia.stylesheet ${REGOLITH_NO_ILIA_STYLESHEET}' "$PARTIAL" \
  && pass "the pickers read ilia.stylesheet" || fail "the partial doesn't read ilia.stylesheet"
grep -qxF 'set_from_resource $wm.clipboard.history_size wm.clipboard.history_size 100' "$PARTIAL" \
  && pass "wm.clipboard.history_size defaults to 100" || fail "no wm.clipboard.history_size default"
# Started once per session: i3 keeps it across restarts, sway across reloads.
[ "$(grep -c '^exec' "$PARTIAL")" = 1 ] \
  && grep -qxF 'exec --no-startup-id regolith-clipboard daemon $wm.clipboard.history_size' "$PARTIAL" \
  && pass "the daemon starts once, with the history size" || fail "the daemon isn't started as expected"

for f in usr/share/regolith/common/config.d/83_text_pickers \
         "scripts/regolith-clipboard usr/bin" "scripts/regolith-emoji usr/bin"; do
  grep -qxF "$f" "$INSTALL" && pass "$INSTALL lists $f" || fail "$INSTALL lacks $f"
done
for f in "$CLIPBOARD" "$EMOJI"; do
  [ -x "$f" ] && pass "$(basename "$f") is executable" || fail "$f is not executable"
  PYTHONDONTWRITEBYTECODE=1 python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$f" \
    && pass "$(basename "$f") parses" || fail "$f has a syntax error"
done

# The helpers with a stand-in ilia, without a display (nothing is put on a
# clipboard), in a throwaway home.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/run"
chmod 700 "$tmp/run"
# FAKE_ILIA: row:N prints the Nth row, text:T prints T, first prints the first
# row after reading only that one, none prints nothing. The arguments go to
# $tmp/ilia.args, the rows read to $tmp/ilia.rows.
cat > "$tmp/bin/ilia" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$TMPD/ilia.args"
case "$FAKE_ILIA" in
  first) IFS= read -r row; printf '%s\n' "$row" > "$TMPD/ilia.rows"; printf '%s' "$row"; exit 0 ;;
esac
cat > "$TMPD/ilia.rows"
case "$FAKE_ILIA" in
  row:*) sed -n "${FAKE_ILIA#row:}p" "$TMPD/ilia.rows" | tr -d '\n' ;;
  text:*) printf '%s' "${FAKE_ILIA#text:}" ;;
esac
SH
chmod +x "$tmp/bin/ilia"
run() {
  env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" \
    TMPD="$tmp" FAKE_ILIA="${FAKE_ILIA:-none}" PYTHONDONTWRITEBYTECODE=1 "$@"
}
hist="$tmp/home/.local/state/regolith/clipboard"
entries() { tr '\n' ' ' < "$hist/index" | sed 's/ $//'; }
digest() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
txt() { echo "$(digest "$1").txt"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2', want '$3'"; fi; }

printf 'abc' | run "$CLIPBOARD" copy
printf 'abc\n' | run "$CLIPBOARD" copy
printf 'secret one' | run "$CLIPBOARD" copy
check "copies are kept newest first" "$(entries)" "$(txt 'secret one') $(txt $'abc\n') $(txt abc)"
printf 'abc' | run "$CLIPBOARD" copy
check "copying an entry again moves it to the top" "$(entries)" "$(txt abc) $(txt 'secret one') $(txt $'abc\n')"
[ "$(stat -c %a "$hist")" = 700 ] && pass "the history directory is private" || fail "$hist is not mode 700"

FAKE_ILIA=row:3 run "$CLIPBOARD" pick -t /style.css
check "pick shows one distinct row per entry" "$(cut -d: -f1 "$tmp/ilia.rows" | tr '\n' ' ')" "1 2 3 "
check "pick passes the label, icon and stylesheet to ilia" "$(tr '\n' ' ' < "$tmp/ilia.args")" \
  "-p textlist -l Clipboard History -i edit-paste -t /style.css "
check "the picked entry becomes the newest" "$(entries)" "$(txt $'abc\n') $(txt abc) $(txt 'secret one')"
for mode in none "text:no such row"; do
  FAKE_ILIA=$mode run "$CLIPBOARD" pick
  check "pick with '$mode' changes nothing" "$(entries)" "$(txt $'abc\n') $(txt abc) $(txt 'secret one')"
done
FAKE_ILIA=row:2 run "$CLIPBOARD" pick
FAKE_ILIA=first run "$CLIPBOARD" pick && rc=0 || rc=$?
check "pick works when ilia reads only the first row" "$rc $(entries)" "0 $(txt abc) $(txt $'abc\n') $(txt 'secret one')"

FAKE_ILIA=row:3 run "$CLIPBOARD" delete -t /style.css
check "delete removes the chosen entry only" "$(entries)" "$(txt abc) $(txt $'abc\n')"
grep -rqF 'secret one' "$tmp/home" && fail "a deleted entry is still on disk" || pass "a deleted entry leaves nothing on disk"

mkdir -p "$tmp/run/regolith-clipboard" && echo 3 > "$tmp/run/regolith-clipboard/size"
for i in 1 2 3 4; do printf 'item %s' "$i" | run "$CLIPBOARD" copy; done
check "the history keeps the newest wm.clipboard.history_size entries" "$(entries)" \
  "$(txt 'item 4') $(txt 'item 3') $(txt 'item 2')"
grep -rqF 'item 1' "$tmp/home" && fail "a dropped entry is still on disk" || pass "a dropped entry leaves nothing on disk"

# A PNG entry is listed by its pixel size.
run python3 - "$CLIPBOARD" <<'PY'
import importlib.machinery, importlib.util, struct, sys, zlib
loader = importlib.machinery.SourceFileLoader("clipboard", sys.argv[1])
spec = importlib.util.spec_from_loader("clipboard", loader)
c = importlib.util.module_from_spec(spec)
loader.exec_module(c)
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
png = (c.PNG_SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 40, 30, 8, 0, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(b"\0" * 41 * 30)) + chunk(b"IEND", b""))
h = c.History()
with h.lock():
    h.add("png", png, 3)
PY
FAKE_ILIA=none run "$CLIPBOARD" pick
head -n1 "$tmp/ilia.rows" | grep -qE '^1: .*image 40x30' && pass "an image row shows its pixel size" \
  || fail "unexpected image row: $(head -n1 "$tmp/ilia.rows")"

FAKE_ILIA=none run "$CLIPBOARD" clear
check "clear offers exactly one row" "$(wc -l < "$tmp/ilia.rows")" 1
check "cancelling clear keeps the history" "$(wc -l < "$hist/index")" 3
FAKE_ILIA=row:1 run "$CLIPBOARD" clear -t /style.css
check "clear empties the history" "$(wc -c < "$hist/index")" 0
check "clear leaves no entry files" "$(find "$hist" -mindepth 1 -printf '%f\n' | sort | tr '\n' ' ')" "index lock "

# The daemon: one per window manager, ending when it exits. A stand-in
# window manager listens on $SWAYSOCK; a stand-in wl-paste --watch runs until
# it is terminated, writing its PID to $tmp/wl-paste.pid.
cat > "$tmp/bin/wl-paste" <<'SH'
#!/bin/bash
echo $$ > "$TMPD/wl-paste.pid"
exec sleep 600
SH
chmod +x "$tmp/bin/wl-paste"
fake_wm() {
  python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8)
while True:
    c, _ = s.accept(); c.close()' "$1" &
  wm=$!
  for _ in $(seq 50); do [ -S "$1" ] && break; sleep 0.1; done
}
daemon() { run env WAYLAND_DISPLAY=wayland-test SWAYSOCK="$1" "$CLIPBOARD" daemon 7; }
fake_wm "$tmp/run/sway-ipc.1"
daemon "$tmp/run/sway-ipc.1" & first=$!
for _ in $(seq 50); do [ -s "$tmp/wl-paste.pid" ] && break; sleep 0.1; done
watcher=$(cat "$tmp/wl-paste.pid" 2>/dev/null || echo 0)
[ "$watcher" -gt 0 ] && kill -0 "$watcher" 2>/dev/null && pass "the daemon runs wl-paste --watch in sway" \
  || fail "the daemon didn't start wl-paste"
check "the daemon records the history size for the session" "$(cat "$tmp/run/regolith-clipboard/size")" 7
daemon "$tmp/run/sway-ipc.1" & second=$!
for _ in $(seq 50); do kill -0 "$second" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$second" 2>/dev/null; then
  fail "a second daemon for the same window manager keeps running"; kill "$second"
else
  wait "$second" && pass "a second daemon for the same window manager ends at once" \
    || fail "a second daemon for the same window manager failed"
fi
kill "$wm"; wait "$wm" 2>/dev/null || true
for _ in $(seq 60); do kill -0 "$first" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$first" 2>/dev/null; then
  fail "the daemon still runs after its window manager exited"; kill "$first"
else
  pass "the daemon ends when its window manager exits"
fi
if kill -0 "$watcher" 2>/dev/null; then
  fail "wl-paste outlived the daemon"; kill "$watcher"
else
  pass "wl-paste ends with the daemon"
fi
[ -e "$tmp/run/regolith-clipboard/daemon.sway-ipc.1.lock" ] && fail "the daemon left its lock behind" \
  || pass "the daemon removes its lock"

if [ -r "$EMOJI_TEST" ]; then
  FAKE_ILIA=none run "$EMOJI"
  check "the emoji list has every fully-qualified emoji once" "$(wc -l < "$tmp/ilia.rows")" \
    "$(grep -c '; fully-qualified' "$EMOJI_TEST")"
  check "the emoji picker passes the label and icon to ilia" "$(head -n6 "$tmp/ilia.args" | tr '\n' ' ')" \
    "-p textlist -l Emoji -i face-smile-big "
  row=$(grep -m1 -F ' family: man, woman, girl, boy' "$tmp/ilia.rows")
  FAKE_ILIA="text:$row" run "$EMOJI" -t /style.css
  # man, ZWJ, woman, ZWJ, girl, ZWJ, boy, in UTF-8
  family=$(printf '\360\237\221\250\342\200\215\360\237\221\251\342\200\215\360\237\221\247\342\200\215\360\237\221\246')
  check "the chosen emoji is copied exactly, joiners kept" "$(head -n1 "$hist/index")" "$(txt "$family")"
  FAKE_ILIA=none run "$EMOJI"
  check "the emoji picked last is listed first" "$(head -n1 "$tmp/ilia.rows")" "$row"
else
  echo "skip: $EMOJI_TEST is missing"
fi

exit $status
