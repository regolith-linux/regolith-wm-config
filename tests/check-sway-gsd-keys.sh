#!/bin/bash
# Run regolith-sway-gsd-keys against stand-ins for gnome-settings-daemon's
# rfkill plugin, UPower and the notification server on a private D-Bus, and
# check the property changes and notifications. (Ejecting needs a real
# drive, so it isn't run here.) Run from the top of the source tree
# (debian/rules runs it at build time).
set -eu

if [ -z "${DBUS_SESSION_BUS_ADDRESS-}" ] || [ "${CHECK_GSD_KEYS_BUS-}" != 1 ]; then
    exec env CHECK_GSD_KEYS_BUS=1 dbus-run-session -- bash "$0" "$@"
fi
# UPower is on the system bus: put it on the private bus as well
export DBUS_SYSTEM_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS

HELPER=$PWD/scripts/regolith-sway-gsd-keys
WORK=$(mktemp -d)
status=0
export XDG_RUNTIME_DIR=$WORK

# The stand-ins: properties from $WORK/state (JSON), each property change
# and notification logged to $WORK/log
cat > "$WORK/services.py" <<'PY'
import json, sys
from gi.repository import Gio, GLib
state_file, log_file = sys.argv[1:]
NODE = Gio.DBusNodeInfo.new_for_xml("""<node>
<interface name="org.freedesktop.Notifications">
  <method name="Notify">
    <arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/>
    <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/>
    <arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/>
  </method>
</interface>
<interface name="org.gnome.SettingsDaemon.Rfkill">
  <property name="AirplaneMode" type="b" access="readwrite"/>
  <property name="HardwareAirplaneMode" type="b" access="read"/>
  <property name="HasAirplaneMode" type="b" access="read"/>
  <property name="BluetoothAirplaneMode" type="b" access="readwrite"/>
  <property name="BluetoothHardwareAirplaneMode" type="b" access="read"/>
  <property name="BluetoothHasAirplaneMode" type="b" access="read"/>
</interface>
<interface name="org.freedesktop.UPower.Device">
  <property name="Type" type="u" access="read"/>
  <property name="Percentage" type="d" access="read"/>
  <property name="IconName" type="s" access="read"/>
</interface>
</node>""")
TYPES = {"Type": "u", "Percentage": "d", "IconName": "s"}

def log(line):
    with open(log_file, "a") as f:
        f.write(line + "\n")

def state():
    with open(state_file) as f:
        return json.load(f)

def call(conn, sender, path, iface, method, params, invocation):
    _, _, icon, summary, body, _, hints, _ = params.unpack()
    log(f"notify [{icon}] [{summary}] [{body}] value={hints.get('value')} transient={hints.get('transient')}")
    invocation.return_value(GLib.Variant("(u)", (1,)))

def get(conn, sender, path, iface, prop):
    return GLib.Variant(TYPES.get(prop, "b"), state()[prop])

def set_(conn, sender, path, iface, prop, value):
    s = state()
    s[prop] = value.unpack()
    with open(state_file, "w") as f:
        json.dump(s, f)
    log(f"set {prop}={str(value.unpack()).lower()}")
    return True

def acquired(conn, name):
    for path, iface in (("/org/freedesktop/Notifications", 0),
                        ("/org/gnome/SettingsDaemon/Rfkill", 1),
                        ("/org/freedesktop/UPower/devices/DisplayDevice", 2)):
        register = getattr(conn, "register_object_with_closures2", conn.register_object)
        register(path, NODE.interfaces[iface], call, get, set_)
    for name in ("org.freedesktop.Notifications", "org.gnome.SettingsDaemon.Rfkill",
                 "org.freedesktop.UPower"):
        Gio.bus_own_name_on_connection(conn, name, 0, None, None)

Gio.bus_own_name(Gio.BusType.SESSION, "org.regolith.Test", 0, acquired, None, None)
GLib.MainLoop().run()
PY

# set_state <json>: the stand-ins' properties
set_state() {
    printf '%s\n' "$1" > "$WORK/state"
}
set_state '{}'
python3 "$WORK/services.py" "$WORK/state" "$WORK/log" &
services=$!
trap 'kill $services; rm -rf "$WORK"' EXIT
gdbus wait --session --timeout 10 org.freedesktop.UPower

# run <argument>: run the helper (a new key press, so not debounced)
run() {
    rm -f "$WORK"/regolith-sway-gsd-keys-*
    : > "$WORK/log"
    python3 "$HELPER" "$@" 2> "$WORK/err" || echo "exit status $?" >> "$WORK/log"
}

# expect <description> <line>...: the log is exactly these lines
expect() {
    local desc=$1; shift
    if [ "$(cat "$WORK/log")" = "$(printf '%s\n' "$@")" ]; then
        echo "ok   $desc"
    else
        echo "FAIL $desc: expected:" >&2
        printf '       %s\n' "$@" >&2
        echo "     got:" >&2
        sed 's/^/       /' "$WORK/log" "$WORK/err" >&2
        status=1
    fi
}

RFKILL='"AirplaneMode": false, "HardwareAirplaneMode": false, "HasAirplaneMode": true,
  "BluetoothAirplaneMode": false, "BluetoothHardwareAirplaneMode": false, "BluetoothHasAirplaneMode": true'
set_state "{$RFKILL}"
run rfkill
expect 'airplane mode key: on' 'set AirplaneMode=true' \
    'notify [airplane-mode-symbolic] [Airplane Mode Enabled] [] value=None transient=True'
: > "$WORK/log"
python3 "$HELPER" rfkill
expect 'the same press again within a second: ignored'
run rfkill
expect 'airplane mode key: off' 'set AirplaneMode=false' \
    'notify [airplane-mode-disabled-symbolic] [Airplane Mode Disabled] [] value=None transient=True'
run bluetooth
expect 'Bluetooth key: off' 'set BluetoothAirplaneMode=true' \
    'notify [bluetooth-disabled-symbolic] [Bluetooth Disabled] [] value=None transient=True'
run bluetooth
expect 'Bluetooth key: on' 'set BluetoothAirplaneMode=false' \
    'notify [bluetooth-active-symbolic] [Bluetooth Enabled] [] value=None transient=True'
set_state "{${RFKILL/\"HardwareAirplaneMode\": false/\"HardwareAirplaneMode\": true}}"
run rfkill
expect 'hardware switch on: unchanged' \
    'notify [airplane-mode-symbolic] [Hardware Airplane Mode] [] value=None transient=True'
set_state "{${RFKILL/\"HasAirplaneMode\": true/\"HasAirplaneMode\": false}}"
run rfkill
expect 'no radios: nothing'

set_state '{"Type": 2, "Percentage": 76.4, "IconName": "battery-good-symbolic"}'
run battery
expect 'battery key: level' 'notify [battery-good-symbolic] [Battery] [76%] value=76 transient=True'
set_state '{"Type": 3, "Percentage": 100.0, "IconName": ""}'
run battery
expect 'battery key, UPS: level' 'notify [battery-symbolic] [Battery] [100%] value=100 transient=True'
set_state '{"Type": 1, "Percentage": 0.0, "IconName": "ac-adapter-symbolic"}'
run battery
expect 'battery key, no battery: nothing'

run frobnicate
expect 'unknown action: usage' 'exit status 2'

exit $status
