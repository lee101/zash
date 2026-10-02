f=var
f() { echo func; }
unset -v f
f
