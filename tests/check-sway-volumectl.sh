#!/bin/bash
# Check regolith-sway-volumectl and the volume keys in 65_media_keybindings:
# - with a volumectl that has -n (help lists it), the helper adds -n;
# - with an older volumectl, which rejects -n, it passes the arguments alone;
# - either way the arguments reach volumectl unchanged and its exit status
#   comes back;
# - every volume key runs the helper, never volumectl -n directly, and the
#   install file ships the helper.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

HELPER=$PWD/scripts/regolith-sway-volumectl
KEYS=$PWD/usr/share/regolith/sway/config.d/65_media_keybindings
INSTALL=$PWD/debian/regolith-sway-media-keys.install
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

# Stand-ins for avizo's volumectl. Both print help as volumectl -h does; the
# new one lists -n. They log their arguments, one per line, and exit with
# $VOLUMECTL_STATUS; the old one rejects -n as avizo 0.1.6 does.
stub() { # stub <dir> <has -n: yes|no>
    mkdir -p "$1"
    cat > "$1/volumectl" <<STUB
#!/bin/sh
for a in "\$@"; do [ "\$a" = -h ] && {
    echo "Options (also accepted after the command):"
    echo "  -m               Control the source (mic) instead of sink (output)."
    [ $2 = yes ] && echo "  -n               Name the device in the notification, unless it is a"
    echo "  -u               Unmute when changing the volume (+|-|=)."
    exit 0; }; done
if [ $2 = no ]; then
    for a in "\$@"; do [ "\$a" = -n ] && { echo "volumectl: unknown option: -n" >&2; exit 1; }; done
fi
printf '%s\n' "\$@" > "$WORK/args"
exit \${VOLUMECTL_STATUS:-0}
STUB
    chmod +x "$1/volumectl"
}
stub "$WORK/new" yes
stub "$WORK/old" no

run() { # run <old|new> <args...>; prints the arguments volumectl got, joined by |
    rm -f "$WORK/args"
    PATH="$WORK/$1:$PATH" "$HELPER" "${@:2}" || return
    paste -sd '|' "$WORK/args"
}

check() { # check <old|new> <expected> <args...>
    local got
    got=$(run "$1" "${@:3}") || { fail "$1 volumectl ${*:3}: exit $?"; return; }
    if [ "$got" = "$2" ]; then pass "$1 volumectl, ${*:3} -> $got"
    else fail "$1 volumectl, ${*:3}: got '$got', want '$2'"; fi
}

check new '-n|-u|+|5' -u + 5
check new '-n|-u|-|2' -u - 2
check new '-n|%' %
check new '-n|-m|%' -m %
check new '-n|-u|+|5%' -u + 5%
check new '-n|-u|+|a b' -u + 'a b'
check old '-u|+|5' -u + 5
check old '-u|-|2' -u - 2
check old '%' %
check old '-m|%' -m %
check old '-u|+|a b' -u + 'a b'

for v in old new; do
    if VOLUMECTL_STATUS=3 PATH="$WORK/$v:$PATH" "$HELPER" -u + 5; then rc=0; else rc=$?; fi
    [ "$rc" = 3 ] && pass "$v volumectl: exit status 3 comes back" \
        || fail "$v volumectl: exit status $rc, want 3"
done

# The keys: every volumectl binding goes through the helper
direct=$(grep -cE '^bind(sym|code) .* exec volumectl( |$)' "$KEYS" || true)
helper=$(grep -cE '^bindsym --locked .*XF86Audio(Raise|Lower)Volume exec regolith-sway-volumectl -u [+-] |^bindsym --locked .*XF86Audio(Mic)?Mute exec regolith-sway-volumectl (-m )?%$' "$KEYS" || true)
[ "$direct" = 0 ] && pass "no key runs volumectl directly" || fail "$direct keys run volumectl directly"
[ "$helper" = 15 ] && pass "15 volume keys run regolith-sway-volumectl" || fail "$helper volume keys run the helper, want 15"
grep -qx 'scripts/regolith-sway-volumectl usr/bin' "$INSTALL" \
    && pass "regolith-sway-media-keys ships the helper" || fail "the install file misses the helper"

exit $status
