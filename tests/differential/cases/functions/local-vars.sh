x=global
f() { local x=local; echo $x; }
f
echo $x
