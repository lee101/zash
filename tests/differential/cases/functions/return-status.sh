f() { return 3; }
f; echo $?
g() { true; return; }
g; echo $?
