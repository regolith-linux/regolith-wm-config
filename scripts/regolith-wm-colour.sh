# shellcheck shell=bash
# Colour helpers for the Regolith scripts that draw a look's colours in sway
# (regolith-set-swaybg, regolith-sway-gtklock). Sourced by bash; installed in
# /usr/lib/regolith.

# to_hex <colour>: print the colour as #rrggbb, or fail. Colours can be
# anything GNOME accepts: #RGB, #RRGGBB, #RRRGGGBBB, #RRRRGGGGBBBB, rgb(),
# rgba() or a colour name, looked up in $REGOLITH_RGB_TXT
# (/usr/share/X11/rgb.txt by default).
to_hex() {
  local c=$1 n r g b
  c=${c#"${c%%[![:space:]]*}"}
  c=${c%"${c##*[![:space:]]}"}

  if [[ $c =~ ^#([[:xdigit:]]+)$ ]]; then
    local hex=${BASH_REMATCH[1],,}
    n=$(( ${#hex} / 3 ))
    if (( ${#hex} % 3 != 0 || n < 1 || n > 4 )); then
      return 1
    fi
    r=${hex:0:n}; g=${hex:n:n}; b=${hex:2*n:n}
    if (( n == 1 )); then
      printf '#%02x%02x%02x\n' $((16#$r * 17)) $((16#$g * 17)) $((16#$b * 17))
    else
      printf '#%s%s%s\n' "${r:0:2}" "${g:0:2}" "${b:0:2}"
    fi
    return 0
  fi

  local num='[[:space:]]*([0-9]+(\.[0-9]+)?%?)[[:space:]]*'
  if [[ ${c,,} =~ ^rgba?\($num,$num,$num(,[^\)]*)?\)$ ]]; then
    local out=() v
    for v in "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}"; do
      if [[ $v == *% ]]; then
        v=$(awk -v p="${v%\%}" 'BEGIN { v = p * 255 / 100; if (v > 255) v = 255; printf "%d", v + 0.5 }')
      else
        v=${v%%.*}
      fi
      (( v > 255 )) && v=255
      out+=("$v")
    done
    printf '#%02x%02x%02x\n' "${out[@]}"
    return 0
  fi

  # Colour names: GNOME (Pango) uses the X11 colour names, without regard to
  # case or spaces
  local name=${c,,}
  name=${name//[[:space:]]/}
  local rgb_txt=${REGOLITH_RGB_TXT:-/usr/share/X11/rgb.txt}
  [[ -n $name && -r $rgb_txt ]] || return 1
  awk -v want="$name" '
    /^[[:space:]]*!/ { next }
    NF >= 4 {
      n = ""
      for (i = 4; i <= NF; i++) n = n $i
      if (tolower(n) == want) { printf "#%02x%02x%02x\n", $1, $2, $3; found = 1; exit }
    }
    END { exit !found }' "$rgb_txt"
}
