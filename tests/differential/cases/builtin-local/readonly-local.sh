f() { local -r x=1; x=2 2>&1 | sed 's/^[^:]*: //'; echo $x; }
f
