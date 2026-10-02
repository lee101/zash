declare -A m
while IFS== read -r k v; do m[$k]=$v; done < kv.env
echo ${m[A]} ${m[B]} "${m[C]}"
