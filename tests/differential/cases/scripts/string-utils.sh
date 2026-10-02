trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
echo "[$(trim '   padded text   ')]"
upper() { echo "${1^^}"; }
upper hello
repeat() { local i out=; for ((i=0;i<$2;i++)); do out+=$1; done; echo "$out"; }
repeat ab 3
