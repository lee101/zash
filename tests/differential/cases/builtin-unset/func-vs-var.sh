f=var
f() { echo func; }
unset f
echo "[${f-unset}]"
f
unset -f f
f 2>/dev/null; echo $?
