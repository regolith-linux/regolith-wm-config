#!/bin/bash
# Check the default terminal of common/config.d/15_base_launchers: run the
# Super+Enter command line as i3 and sway do (/bin/sh -c) against stand-ins,
# with and without xdg-terminal-exec on the PATH (Debian bookworm and Ubuntu
# jammy have no xdg-terminal-exec package). Run from the top of the source
# tree (debian/rules runs it at build time).
set -eu

PARTIAL=$PWD/usr/share/regolith/common/config.d/15_base_launchers
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
status=0

default=$(sed -n 's/^set_from_resource \$wm\.program\.terminal wm\.program\.terminal //p' "$PARTIAL")
binding=$(sed -n 's/^bindsym \$mod+\$wm\.binding\.terminal exec --no-startup-id //p' "$PARTIAL")
if [ -z "$default" ] || [ -z "$binding" ]; then
    echo "FAIL the terminal resource or binding is missing from $PARTIAL"
    exit 1
fi
cmd=${binding//\$wm.program.terminal/$default}

mkdir -p "$WORK/with" "$WORK/without"
for dir in with without; do
    printf '#!/bin/sh\necho "[systemd-run $*]"\n' > "$WORK/$dir/systemd-run"
done
printf '#!/bin/sh\nexit 0\n' > "$WORK/with/xdg-terminal-exec"
chmod +x "$WORK/with/"* "$WORK/without/"*

# expect <description> <path dir> <expected output>
expect() {
    local got
    got=$(PATH="$WORK/$2" /bin/sh -c "$cmd" 2>&1) || true
    if [ "$got" = "$3" ]; then
        echo "ok   $1"
    else
        printf 'FAIL %s: expected:\n       %s\n     got:\n       %s\n' "$1" "$3" "$got"
        status=1
    fi
}

expect "xdg-terminal-exec installed: Super+Enter runs it" with \
    "[systemd-run --user --scope $WORK/with/xdg-terminal-exec]"
expect "no xdg-terminal-exec: Super+Enter runs x-terminal-emulator" without \
    "[systemd-run --user --scope x-terminal-emulator]"

exit $status
