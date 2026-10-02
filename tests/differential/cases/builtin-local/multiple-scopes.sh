x=0
f() { local x=1; g; echo "f:$x"; }
g() { local x=2; echo "g:$x"; }
f
echo "top:$x"
