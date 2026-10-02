v=global
f() { local v=local; unset v; echo "[${v-unset}]"; }
f
echo $v
