#!/bin/bash
# Resolve the key bindings of sway's 80_grimshot with the default resources
# for each value of wm.mod, and check that sway won't show its config error
# bar for them (a key bound twice needs --no-warn on the later line) and that
# each key runs the intended command. Run from the top of the source tree
# (debian/rules runs it at build time).
set -eu

PARTIAL=$PWD/usr/share/regolith/sway/config.d/80_grimshot
status=0

# bindings <mod>: print "<key>\t<no-warn>\t<command>" for each bindsym line,
# in order, with $mod and the resource defaults filled in and the modifiers
# written the way sway compares them (Alt is Mod1, Ctrl is Control, Super is
# Mod4, sorted)
bindings() {
    awk -v mod="$1" '
    function norm(combo,    n, parts, i, j, t, key, out) {
        n = split(combo, parts, "+")
        key = parts[n]
        for (i = 1; i < n; i++) {
            if (parts[i] == "Alt") parts[i] = "Mod1"
            else if (parts[i] == "Ctrl") parts[i] = "Control"
            else if (parts[i] == "Super") parts[i] = "Mod4"
        }
        for (i = 1; i < n; i++)
            for (j = i + 1; j < n; j++)
                if (parts[j] < parts[i]) { t = parts[i]; parts[i] = parts[j]; parts[j] = t }
        out = ""
        for (i = 1; i < n; i++) out = out parts[i] "+"
        return out key
    }
    $1 == "set_from_resource" { def[$2] = $4 }
    $1 == "bindsym" {
        nowarn = "warn"; i = 2
        while ($i ~ /^--/) { if ($i == "--no-warn") nowarn = "no-warn"; i++ }
        # Replace each +-separated part that is exactly a variable name
        n = split($i, parts, "+"); combo = ""
        for (j = 1; j <= n; j++) {
            if (parts[j] == "$mod") parts[j] = mod
            else if (parts[j] in def) parts[j] = def[parts[j]]
            combo = combo (j > 1 ? "+" : "") parts[j]
        }
        cmd = ""
        for (j = i + 1; j <= NF; j++) cmd = cmd (j > i + 1 ? " " : "") $j
        printf "%s\t%s\t%s\n", norm(combo), nowarn, cmd
    }' "$PARTIAL"
}

# check_mod <mod> <key> <command>...: no error bar, and each key runs its command
check_mod() {
    local mod=$1; shift
    local list
    list=$(bindings "$mod")
    # A key bound again without --no-warn makes sway show its error bar
    local dup
    dup=$(printf '%s\n' "$list" | awk -F '\t' 'seen[$1]++ && $2 != "no-warn" { print $1 }')
    if [ -n "$dup" ]; then
        echo "FAIL wm.mod $mod: bound again without --no-warn (sway error bar): $dup"
        status=1
    else
        echo "ok   wm.mod $mod: no key bound twice without --no-warn"
    fi
    while [ "$#" -gt 0 ]; do
        local key=$1 want=$2 got
        shift 2
        got=$(printf '%s\n' "$list" | awk -F '\t' -v k="$key" '$1 == k { c = $3 } END { print c }')
        if [ "$got" = "$want" ]; then
            echo "ok   wm.mod $mod: $key runs '$want'"
        else
            echo "FAIL wm.mod $mod: $key runs '$got', expected '$want'"
            status=1
        fi
    done
}

# The six X11-session keys, the same whatever wm.mod is
x11=(
    Print "exec grimshot --notify save screen"
    Shift+Print "exec grimshot --notify save area"
    Mod1+Print "exec grimshot --notify save active"
    Control+Print "exec grimshot --notify copy screen"
    Control+Shift+Print "exec grimshot --notify copy area"
    Control+Mod1+Print "exec grimshot --notify copy active"
)

check_mod Mod4 "${x11[@]}" \
    Mod4+Print "exec grimshot copy active" \
    Mod4+Shift+Print "exec grimshot --notify savecopy anything" \
    Control+Mod4+Shift+Print "exec grimshot --notify save screen"

# With Alt as $mod, $mod+Print is Alt+Print: the X11-session key wins, as in
# i3; the other two sway-only keys keep working
check_mod Mod1 "${x11[@]}" \
    Mod1+Shift+Print "exec grimshot --notify savecopy anything" \
    Control+Mod1+Shift+Print "exec grimshot --notify save screen"

exit "$status"
