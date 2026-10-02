f() { false; }
f; echo $?
f() { true; }
f; echo $?
