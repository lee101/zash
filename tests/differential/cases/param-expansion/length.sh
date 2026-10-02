v=hello
echo ${#v}
v=
echo ${#v}
unset v
echo ${#v}
set -- a bb ccc
echo ${#@} ${#1} ${#2} ${#3}
