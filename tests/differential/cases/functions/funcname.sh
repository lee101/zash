f() { echo $FUNCNAME; }
f
g() { f; echo $FUNCNAME; }
g
