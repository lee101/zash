f() { local i; for i in 1 2 3; do :; done; echo $i; }
i=orig
f
echo $i
