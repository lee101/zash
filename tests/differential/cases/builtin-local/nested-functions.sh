f() { local v=f; g; }
g() { echo "g sees $v"; }
f
