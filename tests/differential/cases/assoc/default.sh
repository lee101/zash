declare -A m
echo "${m[x]:-default}" "${m[x]-d2}"
