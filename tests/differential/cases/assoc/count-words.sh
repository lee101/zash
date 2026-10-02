declare -A c
for w in a b a c a b; do c[$w]=$(( ${c[$w]:-0} + 1 )); done
for k in $(printf '%s\n' "${!c[@]}" | sort); do echo "$k ${c[$k]}"; done
