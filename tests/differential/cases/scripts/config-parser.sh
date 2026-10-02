declare -A cfg
while IFS== read -r k v; do
  [[ -z $k || $k == \#* ]] && continue
  cfg[$k]=$v
done < kv.env
for k in $(printf '%s\n' "${!cfg[@]}" | sort); do echo "$k -> ${cfg[$k]}"; done
