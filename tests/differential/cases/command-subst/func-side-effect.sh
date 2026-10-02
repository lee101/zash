c=0
f() { c=$((c+1)); echo $c; }
x=$(f)
echo $x $c
