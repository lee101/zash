[[ "ac" =~ a(b)?c ]]
echo "[${BASH_REMATCH[1]}]" ${#BASH_REMATCH[@]}
