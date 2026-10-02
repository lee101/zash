x=1
f() { local x=2; unset x; echo "[${x-unset}]"; }
f
echo $x
