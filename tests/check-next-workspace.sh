#!/bin/bash
# Check the next-free-workspace partials of both sessions (i3's
# 40_next-workspace, sway's 40_childe):
# - they bind the same keys, from the same resources and defaults, to the same
#   childe commands;
# - the workspace-names daemon is opt-in through wm.workspace.app_names
#   (default no), started with exec (once per session, not on reloads), and
#   only when the resource is yes;
# - the packages that ship them depend on the same childe version.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

I3=$PWD/usr/share/regolith/i3/config.d/40_next-workspace
SWAY=$PWD/usr/share/regolith/sway/config.d/40_childe
CONTROL=$PWD/debian/control
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

# bindings <partial>: print "<key>\t<command>" for each bindsym line, with the
# resource defaults filled in
bindings() {
    awk '
    $1 == "set_from_resource" { def[$2] = $4 }
    $1 == "bindsym" {
        n = split($2, parts, "+"); combo = ""
        for (j = 1; j <= n; j++) {
            if (parts[j] in def) parts[j] = def[parts[j]]
            combo = combo (j > 1 ? "+" : "") parts[j]
        }
        cmd = ""
        for (j = 3; j <= NF; j++) cmd = cmd (j > 3 ? " " : "") $j
        printf "%s\t%s\n", combo, cmd
    }' "$1"
}

expected=$(printf '%s\t%s\n' \
    '$mod+grave' 'exec --no-startup-id childe' \
    '$mod+Shift+grave' 'exec --no-startup-id childe --move-window' \
    '$mod+$alt+grave' 'exec --no-startup-id childe --move-window --follow')

for partial in "$I3" "$SWAY"; do
    name=${partial#"$PWD"/}
    got=$(bindings "$partial")
    if [ "$got" = "$expected" ]; then
        pass "$name binds the three next-free keys to childe"
    else
        fail "$name bindings differ from the expected ones:"
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$got") || true
    fi
    for res in next_free move_next_free take_next_free; do
        line=$(grep "^set_from_resource \$wm.binding.$res " "$partial" || true)
        [ -n "$line" ] && pass "$name reads wm.binding.$res" || fail "$name doesn't read wm.binding.$res"
    done
    if grep -q 'i3-next-workspace' "$partial"; then
        fail "$name still runs i3-next-workspace"
    fi
done

# Both sessions: the same resources, keys, commands and daemon line
same() { grep -E '^(set_from_resource|bindsym|exec|exec_always) ' "$1"; }
if [ "$(same "$I3")" = "$(same "$SWAY")" ]; then
    pass "both sessions have the same resources, bindings and exec lines"
else
    fail "the sessions differ:"
    diff <(same "$I3") <(same "$SWAY") || true
fi

# The opt-in daemon
for partial in "$I3" "$SWAY"; do
    name=${partial#"$PWD"/}
    if grep -qxF 'set_from_resource $wm.workspace.app_names wm.workspace.app_names no' "$partial"; then
        pass "$name reads wm.workspace.app_names, default no"
    else
        fail "$name doesn't read wm.workspace.app_names with the default no"
    fi
    n=$(grep -v '^ *#' "$partial" | grep -c -- '--workspace-names' || true)
    daemon=$(grep -E '^exec .*--workspace-names' "$partial" || true)
    if [ "$n" = 1 ] && [ -n "$daemon" ]; then
        pass "$name starts the daemon from one exec line (not exec_always)"
    else
        fail "$name: expected one exec line (not exec_always) for the daemon"
        continue
    fi

    # Run the line the way the window manager does: variables replaced, then
    # sh -c, with a stub childe that records how it was started
    stub=$(mktemp -d)
    printf '#!/bin/sh\necho "$*" >> "%s/started"\n' "$stub" > "$stub/childe"
    chmod +x "$stub/childe"
    command=${daemon#exec }
    command=${command#--no-startup-id }
    for value in no yes "" "yes please"; do
        rm -f "$stub/started"
        PATH=$stub:$PATH sh -c "${command//\$wm.workspace.app_names/$value}" || true
        started=$(cat "$stub/started" 2> /dev/null || true)
        if [ "$value" = yes ]; then
            [ "$started" = "--workspace-names" ] &&
                pass "$name: wm.workspace.app_names: yes starts 'childe --workspace-names'" ||
                fail "$name: wm.workspace.app_names: yes started '$started'"
        else
            [ -z "$started" ] &&
                pass "$name: wm.workspace.app_names: '$value' doesn't start the daemon" ||
                fail "$name: wm.workspace.app_names: '$value' started '$started'"
        fi
    done
    rm -rf "$stub"
done

# depends <package>: print the package's Depends field on one line
depends() {
    awk -v p="$1" '
    /^Package:/ { inpkg = ($2 == p); field = 0; next }
    inpkg && /^Depends:/ { field = 1; sub(/^Depends:/, ""); printf "%s", $0; next }
    inpkg && field && /^ / { printf "%s", $0; next }
    inpkg && field { field = 0 }' "$CONTROL"
}
i3_childe=$(depends regolith-i3-next-workspace | tr ',' '\n' | grep -E '^ *childe( |$)' | xargs || true)
sway_childe=$(depends regolith-sway-next-workspace | tr ',' '\n' | grep -E '^ *childe( |$)' | xargs || true)
if [ -n "$i3_childe" ] && [ "$i3_childe" = "$sway_childe" ]; then
    case "$i3_childe" in
        *'(>='*) pass "both packages depend on $i3_childe" ;;
        *) fail "the childe dependency has no minimum version: $i3_childe" ;;
    esac
else
    fail "regolith-i3-next-workspace depends on '$i3_childe', regolith-sway-next-workspace on '$sway_childe'"
fi
if depends regolith-i3-next-workspace | grep -q 'i3-next-workspace'; then
    fail "regolith-i3-next-workspace still depends on i3-next-workspace"
fi

exit "$status"
