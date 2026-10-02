v=1
f() { unset v; }
f
echo "[${v-unset}]"
