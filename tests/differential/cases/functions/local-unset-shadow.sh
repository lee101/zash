x=global
f() { local x; echo "[${x-unset}]"; x=set; echo $x; }
f
echo $x
