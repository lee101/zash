[[ abc123 =~ [0-9]+ ]] && echo m
echo ${BASH_REMATCH[0]}
[[ abc =~ ^a ]] && echo anchored
[[ abc =~ ^b ]] || echo nomatch
