to_bin() { local n=$1 out=; while (( n > 0 )); do out=$((n%2))$out; n=$((n/2)); done; echo "${out:-0}"; }
to_bin 10; to_bin 255; to_bin 0
