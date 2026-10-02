x=outer
g() { echo $x; }
f() { local x=inner; g; }
f
g
