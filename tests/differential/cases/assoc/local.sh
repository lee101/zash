f() { local -A l=([x]=1); echo ${l[x]}; }
f
echo "[${l[x]}]"
