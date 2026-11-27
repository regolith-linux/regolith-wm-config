#!/bin/bash
# Check regolith-sway-screen-reader:
# - the bindings partial is what tests/orca-keymap.py writes from the key map,
#   every binding runs something regolith-orcactl serves, and no default-mode
#   key is one the shipped partials already bind;
# - the package is sway-only (the i3 session is unchanged);
# - regolith-orcactl drives stand-ins for Orca 50 (org.gnome.Orca.Service) and
#   Orca 51 (org.gnome.Orca1.Service), and stays silent when Orca isn't running;
# - regolith-sway-screen-reader applies the bindings to a stand-in sway only
#   while the screen reader setting is on and Orca is on the bus, re-applies
#   them after a reload and announces the browse-keys mode.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

if [ -z "${DBUS_SESSION_BUS_ADDRESS-}" ] || [ "${CHECK_SCREEN_READER_BUS-}" != 1 ]; then
    exec env CHECK_SCREEN_READER_BUS=1 dbus-run-session -- bash "$0" "$@"
fi

SRC=$PWD
CTL=$SRC/scripts/regolith-orcactl
GATE=$SRC/scripts/regolith-sway-screen-reader
DATA=$SRC/usr/share/regolith/sway/screen-reader
PARTIAL=$SRC/usr/share/regolith/sway/config.d/45_screen_reader
INSTALL=$SRC/debian/regolith-sway-screen-reader.install
WORK=$(mktemp -d)
status=0
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; status=1; }

export XDG_RUNTIME_DIR=$WORK/run
export REGOLITH_ORCACTL_KEYMAP=$DATA/orca-keymap.json
export REGOLITH_SCREEN_READER_BINDINGS=$DATA/orca.conf
mkdir -m 700 "$XDG_RUNTIME_DIR"

###############################################################################
# The partial and the package
###############################################################################
python3 "$SRC/tests/orca-keymap.py" sway "$DATA/orca-keymap.json" "$WORK/orca.conf"
if cmp -s "$WORK/orca.conf" "$DATA/orca.conf"; then
    pass "orca.conf is what tests/orca-keymap.py writes from orca-keymap.json"
else
    fail "orca.conf differs from tests/orca-keymap.py's output:"
    diff -u "$DATA/orca.conf" "$WORK/orca.conf" >&2 || true
fi

python3 - "$SRC" <<'PY' && pass "every binding runs something regolith-orcactl serves, and no default-mode key clashes with a shipped partial" || status=1
import glob, json, re, sys
src = sys.argv[1]
data = f"{src}/usr/share/regolith/sway/screen-reader"
keymap = json.load(open(f"{data}/orca-keymap.json"))["desktop"]
bad = []

def combo(c):
    *mods, key = c.split("+")
    return (frozenset(mods), key)

ours, mode = [], None
for line in open(f"{data}/orca.conf"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    m = re.fullmatch(r"mode (\S+) \{", line)
    if m:
        mode = m.group(1)
        continue
    if line == "}":
        mode = None
        continue
    words = line.split()
    i = 1
    while words[i].startswith("--"):
        i += 1
    keys, command = words[i], " ".join(words[i + 1:])
    if ";" in command or "," in command:
        bad.append(f"[{line}]: sway's IPC would split the command at ; or ,")
    ok = command in ("nop orca key", "mode orca-browse", "mode default",
                     "exec regolith-orcactl prompt", "exec regolith-orcactl prompt --learn",
                     "exec regolith-orcactl prefs")
    m = re.fullmatch(r"exec regolith-orcactl key (\S+)", command)
    if m:
        entry = keymap.get(m.group(1))
        ok = bool(entry and entry["module"])
    if not ok:
        bad.append(f"[{line}]: not a command regolith-orcactl serves")
    if mode is None:
        ours.append(combo(keys))

# Every key the shipped sway session binds, with $variables at their defaults
files = [f"{src}/etc/regolith/sway/config"] + sorted(
    glob.glob(f"{src}/usr/share/regolith/common/config.d/*") +
    glob.glob(f"{src}/usr/share/regolith/sway/config.d/*"))
var = {}
lines = []
for f in files:
    for line in open(f):
        line = line.strip()
        m = re.match(r"set_from_resource (\$\S+) \S+ (\S+)", line) or re.match(r"set (\$\S+) (\S+)$", line)
        if m:
            var.setdefault(m.group(1), m.group(2))
        if line.startswith("bindsym "):
            lines.append(line)

def expand(s):
    for _ in range(5):
        for k in sorted(var, key=len, reverse=True):
            s = s.replace(k, var[k])
    return s

shipped = set()
for line in lines:
    words = expand(line).split()
    i = 1
    while i < len(words) and words[i].startswith("--"):
        i += 1
    if i < len(words):
        shipped.add(combo(words[i]))
for c in ours:
    if c in shipped:
        bad.append(f"{'+'.join(sorted(c[0]) + [c[1]])} is already bound by a shipped partial")
for b in bad:
    print(f"FAIL {b}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY

for f in usr/share/regolith/sway/config.d/45_screen_reader \
         usr/share/regolith/sway/screen-reader/orca.conf \
         usr/share/regolith/sway/screen-reader/orca-keymap.json \
         "scripts/regolith-sway-screen-reader usr/bin" "scripts/regolith-orcactl usr/bin"; do
    grep -qxF "$f" "$INSTALL" && pass "installs $f" || fail "$INSTALL lacks $f"
done
grep -qxF "exec regolith-sway-screen-reader" "$PARTIAL" \
    && pass "the sway partial starts the helper" || fail "$PARTIAL doesn't start regolith-sway-screen-reader"
if grep -qE 'i3|common' "$INSTALL" || grep -rqlE 'orcactl|screen-reader|screen_reader' \
        "$SRC/usr/share/regolith/i3" "$SRC/usr/share/regolith/common" "$SRC/etc/regolith/i3"; then
    fail "the i3 session or the common partials refer to the screen reader bindings"
else
    pass "sway-only: nothing for the i3 session or the common partials"
fi
for x in "$CTL" "$GATE"; do
    [ -x "$x" ] && pass "$(basename "$x") is executable" || fail "$x is not executable"
done

###############################################################################
# Stand-ins: Orca's remote controller (50 or 51) and sway's IPC
###############################################################################
cat > "$WORK/orca.py" <<'PY'
import json, sys
from gi.repository import Gio, GLib
version, keymap_file, log_file = sys.argv[1:]
v1 = version.startswith("51")
name = "org.gnome.Orca1.Service" if v1 else "org.gnome.Orca.Service"
root = "/org/gnome/Orca1/Service" if v1 else "/org/gnome/Orca/Service"
modules = {}
for entry in json.load(open(keymap_file))["desktop"].values():
    if entry["module"]:
        modules.setdefault(entry["module"], set()).add(entry["method"])

def log(line):
    with open(log_file, "a") as f:
        f.write(line + "\n")

SERVICE = f"""<node><interface name="{name}">
<method name="GetVersion"><arg type="s" direction="out"/></method>
<method name="PresentMessage"><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
<method name="ShowPreferences"><arg type="b" direction="out"/></method>
</interface></node>"""

def module_xml(module):
    if not v1:
        return """<node><interface name="org.gnome.Orca.Module">
<method name="ExecuteCommand"><arg type="s" direction="in"/><arg type="b" direction="in"/><arg type="b" direction="out"/></method>
<method name="ListCommands"><arg type="a(ss)" direction="out"/></method>
</interface></node>"""
    methods = "".join(f'<method name="{m}"><arg type="b" direction="in"/><arg type="b" direction="out"/></method>'
                      for m in sorted(modules[module]))
    return f'<node><interface name="org.gnome.Orca1.{module}">{methods}</interface></node>'

def call(conn, sender, path, iface, method, params, inv):
    args = params.unpack()
    if method == "GetVersion":
        return inv.return_value(GLib.Variant("(s)", (version,)))
    if method == "PresentMessage":
        log(f"say {args[0]}")
    elif method == "ShowPreferences":
        log("prefs")
    elif method == "ListCommands":
        return inv.return_value(GLib.Variant("(a(ss))", ([(m, f"Describes {m}") for m in sorted(modules[path.rsplit('/', 1)[1]])],)))
    elif method == "ExecuteCommand":
        log(f"run {path.rsplit('/', 1)[1]}.{args[0]} notify={args[1]}")
    else:
        log(f"run {path.rsplit('/', 1)[1]}.{method} notify={args[0]}")
    inv.return_value(GLib.Variant("(b)", (True,)))

def acquired(conn, _name):
    register = getattr(conn, "register_object_with_closures2", conn.register_object)
    register(root, Gio.DBusNodeInfo.new_for_xml(SERVICE).interfaces[0], call, None, None)
    for module in modules:
        register(f"{root}/{module}", Gio.DBusNodeInfo.new_for_xml(module_xml(module)).interfaces[0], call, None, None)
    Gio.bus_own_name_on_connection(conn, name, 0, None, None)

Gio.bus_own_name(Gio.BusType.SESSION, f"org.regolith.TestOrca{version.split('.')[0]}", 0, acquired, None, None)
GLib.MainLoop().run()
PY

# The sway stand-in keeps the bindings it is given (as sway would, refusing to
# unbind a key that isn't bound), writes them to $WORK/sway-state, and takes
# "reload", "mode NAME" and "quit" lines on the FIFO $WORK/sway-ctl.
cat > "$WORK/sway.py" <<'PY'
import json, os, selectors, socket, struct, sys
sock_path, ctl_path, state_path, log_path = sys.argv[1:]
sel = selectors.DefaultSelector()
bindings, mode, subscribers = {}, ["default"], []

def log(line):
    with open(log_path, "a") as f:
        f.write(line + "\n")

def save():
    with open(state_path + ".tmp", "w") as f:
        json.dump({"mode": mode[0], "bindings": sorted(bindings)}, f)
    os.replace(state_path + ".tmp", state_path)

def send(conn, kind, payload):
    data = json.dumps(payload).encode()
    conn.sendall(b"i3-ipc" + struct.pack("=II", len(data), kind) + data)

def event(kind, payload):
    for c in list(subscribers):
        try:
            send(c, kind, payload)
        except OSError:
            subscribers.remove(c)

def binding_key(words, m):
    i = 1
    while words[i].startswith("--"):
        i += 1
    *mods, key = words[i].split("+")
    return f"{m}:{'+'.join(sorted(mods) + [key])}"

def run(cmd):
    log(cmd)
    words = cmd.split()
    m = "default"
    if words[0] == "mode" and len(words) > 2:
        m, words = words[1], words[2:]
    if words[0] in ("bindsym", "bindcode"):
        bindings[binding_key(words, m)] = " ".join(words)
    elif words[0] in ("unbindsym", "unbindcode"):
        if bindings.pop(binding_key(words, m), None) is None:
            return {"success": False, "error": "Could not find binding"}
    elif words[0] == "mode" and len(words) == 2:
        mode[0] = words[1]
        event(0x80000002, {"change": words[1], "pango_markup": False})
    else:
        return {"success": False, "error": "unknown command"}
    save()
    return {"success": True}

def client(conn):
    try:
        header = conn.recv(14, socket.MSG_WAITALL)
        if len(header) < 14:
            raise OSError
        length, kind = struct.unpack("=II", header[6:])
        payload = conn.recv(length, socket.MSG_WAITALL).decode() if length else ""
    except OSError:
        sel.unregister(conn)
        if conn in subscribers:
            subscribers.remove(conn)
        conn.close()
        return
    if kind == 0:
        send(conn, 0, [run(payload)])
    elif kind == 2:
        log(f"subscribe {payload}")
        subscribers.append(conn)
        send(conn, 2, {"success": True})
    elif kind == 12:
        send(conn, 12, {"name": mode[0]})

def control(fd):
    for line in os.read(fd, 4096).decode().splitlines():
        if line == "reload":
            bindings.clear()
            mode[0] = "default"
            save()
            event(0x80000000, {"change": "reload"})
        elif line.startswith("mode "):
            run(line)
        elif line == "quit":
            sys.exit(0)

server = socket.socket(socket.AF_UNIX)
server.bind(sock_path)
server.listen()
sel.register(server, selectors.EVENT_READ, lambda s: sel.register(s.accept()[0], selectors.EVENT_READ, client))
os.mkfifo(ctl_path)
ctl = os.open(ctl_path, os.O_RDWR | os.O_NONBLOCK)
sel.register(ctl, selectors.EVENT_READ, control)
save()
while True:
    for key, _ in sel.select():
        key.data(key.fileobj)
PY

orca_pid=
start_orca() {
    python3 "$WORK/orca.py" "$1" "$DATA/orca-keymap.json" "$WORK/orca.log" &
    orca_pid=$!
    pids+=("$orca_pid")
    gdbus wait --session --timeout 10 "$2"
}
stop_orca() {
    kill "$orca_pid"
    wait "$orca_pid" 2>/dev/null || true
}

# ctl <args>: run regolith-orcactl; its exit status, stdout and stderr go to $WORK/out
ctl() {
    : > "$WORK/orca.log"
    local rc=0
    python3 "$CTL" "$@" > "$WORK/out" 2>&1 || rc=$?
    echo "exit $rc" >> "$WORK/out"
}
# expect_ctl <description> <expected output> <orca.log line>...
expect_ctl() {
    local desc=$1 out=$2; shift 2
    if [ "$(cat "$WORK/out")" = "$out" ] && [ "$(cat "$WORK/orca.log")" = "$(printf '%s\n' "$@")" ]; then
        pass "$desc"
    else
        fail "$desc: expected [$out] and:"
        printf '       %s\n' "$@" >&2
        echo "     got:" >&2
        sed 's/^/       /' "$WORK/out" "$WORK/orca.log" >&2
    fi
}
# press_recently <binding>: as if regolith-orcactl ran <binding> a moment ago
press_recently() {
    python3 -c 'import sys, time; print(f"{sys.argv[1]}\t{time.monotonic()}", end="")' "$1" \
        > "$XDG_RUNTIME_DIR/regolith-orcactl-last-key"
}

###############################################################################
# regolith-orcactl
###############################################################################
: > "$WORK/orca.log"
for args in "key Orca+t" "say hello" "prefs" "version" "prompt" "prompt --learn"; do
    # shellcheck disable=SC2086
    ctl $args
    expect_ctl "no Orca running: '$args' exits 1 and prints nothing" "exit 1"
done

export REGOLITH_ORCACTL_DOUBLE_PRESS_MS=60000  # the double-press window, widened for slow builders
start_orca 50.3-test org.gnome.Orca.Service
rm -f "$XDG_RUNTIME_DIR/regolith-orcactl-last-key"
ctl key Orca+t
expect_ctl "Orca 50: Orca+t presents the time" "exit 0" "run SystemInformationPresenter.PresentTime notify=True"
ctl key Orca+t
expect_ctl "Orca 50: Orca+t again within the window presents the date" "exit 0" "run SystemInformationPresenter.PresentDate notify=True"
ctl key Orca+t
expect_ctl "Orca 50: a third press is a first press again" "exit 0" "run SystemInformationPresenter.PresentTime notify=True"
REGOLITH_ORCACTL_DOUBLE_PRESS_MS=0 ctl key Orca+t
expect_ctl "Orca 50: Orca+t after the window is a first press" "exit 0" "run SystemInformationPresenter.PresentTime notify=True"
press_recently KP_Enter
ctl key Orca+t
expect_ctl "Orca 50: another key just before doesn't make a double press" "exit 0" "run SystemInformationPresenter.PresentTime notify=True"
ctl key KP_Up
expect_ctl "Orca 50: KP_Up presents the flat review line" "exit 0" "run FlatReviewPresenter.PresentLine notify=True"
ctl key Orca+Ctrl+space
expect_ctl "Orca 50: a command Orca doesn't expose runs nothing" "exit 1"
ctl key Orca+Shift+F13
expect_ctl "Orca 50: a key Orca doesn't bind runs nothing" "exit 1"
ctl run SpeechManager.ToggleSpeech --silent
expect_ctl "Orca 50: run --silent passes notify=False" "exit 0" "run SpeechManager.ToggleSpeech notify=False"
ctl say hello world
expect_ctl "Orca 50: say" "exit 0" "say hello world"
ctl prefs
expect_ctl "Orca 50: prefs" "exit 0" "prefs"
ctl version
expect_ctl "Orca 50: version" "50.3-test
exit 0"
ctl frobnicate
if grep -q "^exit 2$" "$WORK/out" && grep -q "regolith-orcactl key BINDING" "$WORK/out"; then
    pass "an unknown subcommand prints the usage and exits 2"
else
    fail "an unknown subcommand: $(cat "$WORK/out")"
fi
stop_orca

start_orca 51.1-test org.gnome.Orca1.Service
rm -f "$XDG_RUNTIME_DIR/regolith-orcactl-last-key"
ctl key Orca+t
expect_ctl "Orca 51: Orca+t presents the time" "exit 0" "run SystemInformationPresenter.PresentTime notify=True"
ctl key Orca+t
expect_ctl "Orca 51: Orca+t again presents the date" "exit 0" "run SystemInformationPresenter.PresentDate notify=True"
ctl key KP_Add
expect_ctl "Orca 51: KP_Add runs say all" "exit 0" "run SayAllPresenter.SayAll notify=True"
ctl say hi
expect_ctl "Orca 51: say" "exit 0" "say hi"
ctl prefs
expect_ctl "Orca 51: prefs" "exit 0" "prefs"
stop_orca

###############################################################################
# regolith-sway-screen-reader
###############################################################################
mkdir "$WORK/schemas"
cat > "$WORK/schemas/a11y.gschema.xml" <<'XML'
<schemalist>
  <schema id="org.gnome.desktop.a11y.applications" path="/org/gnome/desktop/a11y/applications/">
    <key name="screen-reader-enabled" type="b"><default>false</default></key>
  </schema>
</schemalist>
XML
glib-compile-schemas "$WORK/schemas"
export GSETTINGS_SCHEMA_DIR=$WORK/schemas GSETTINGS_BACKEND=keyfile XDG_CONFIG_HOME=$WORK/config
export SWAYSOCK=$WORK/sway.sock
total=$(grep -c '^ *bind' "$DATA/orca.conf")

python3 "$WORK/sway.py" "$SWAYSOCK" "$WORK/sway-ctl" "$WORK/sway-state" "$WORK/sway.log" &
pids+=($!)
for _ in $(seq 100); do [ -p "$WORK/sway-ctl" ] && break; sleep 0.1; done

bound() { python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["bindings"]))' "$WORK/sway-state"; }
sway_mode() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["mode"])' "$WORK/sway-state"; }
# wait_for <description> <command>...: up to 15 s for the command to succeed
wait_for() {
    local desc=$1; shift
    for _ in $(seq 150); do
        if "$@"; then pass "$desc"; return 0; fi
        sleep 0.1
    done
    fail "$desc (sway has $(bound) bindings, mode $(sway_mode)); helper log:"
    sed 's/^/       /' "$WORK/gate.log" >&2
}
has_bound() { [ "$(bound)" = "$1" ]; }
logged() { grep -qsF "$1" "$2"; }

: > "$WORK/orca.log"
start_orca 50.3-test org.gnome.Orca.Service
python3 "$GATE" 2> "$WORK/gate.log" &
gate=$!
pids+=("$gate")
wait_for "the helper subscribes to sway's workspace and mode events" logged 'subscribe ["workspace", "mode"]' "$WORK/sway.log"
sleep 1
if has_bound 0; then pass "setting off, Orca running: no bindings"; else fail "setting off: $(bound) bindings"; fi

gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled true
wait_for "setting on, Orca running: all $total bindings applied" has_bound "$total"
python3 - "$WORK/sway-state" <<'PY' && pass "the browse and prompt modes got their bindings" || fail "mode bindings missing"
import json, sys
b = json.load(open(sys.argv[1]))["bindings"]
sys.exit(0 if "orca-browse:h" in b and "orca-prompt:Ctrl+Mod1+Escape" in b and "default:Insert+t" in b else 1)
PY

echo reload > "$WORK/sway-ctl"
wait_for "a sway reload: the bindings are applied again" has_bound "$total"
wait_for "the helper logs the reload" logged "sway reloaded" "$WORK/gate.log"

echo "mode orca-browse" > "$WORK/sway-ctl"
wait_for "entering the browse mode is announced" logged "say Browse keys on" "$WORK/orca.log"
echo "mode default" > "$WORK/sway-ctl"
wait_for "leaving it is announced" logged "say Browse keys off" "$WORK/orca.log"

stop_orca
wait_for "Orca quits: every binding removed" has_bound 0
if grep -q "rejected" "$WORK/gate.log"; then fail "sway rejected a command: $(grep rejected "$WORK/gate.log")"; else pass "sway accepted every bind and unbind"; fi

start_orca 51.1-test org.gnome.Orca1.Service
wait_for "Orca 51 starts: the bindings are back" has_bound "$total"

echo "mode orca-browse" > "$WORK/sway-ctl"
wait_for "browse mode entered" logged "say Browse keys on" "$WORK/orca.log"
gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled false
wait_for "setting off: every binding removed" has_bound 0
if [ "$(sway_mode)" = default ]; then pass "setting off while in the browse mode: back to the default mode"; else fail "mode is $(sway_mode)"; fi

rc=0
timeout 10 python3 "$GATE" 2>> "$WORK/gate.log" || rc=$?
[ "$rc" = 0 ] && pass "a second helper for the same sway exits at once" || fail "a second helper exited $rc"

echo quit > "$WORK/sway-ctl"
for _ in $(seq 100); do kill -0 "$gate" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$gate" 2>/dev/null; then fail "the helper outlives sway"; else pass "the helper exits with sway"; fi

exit $status
