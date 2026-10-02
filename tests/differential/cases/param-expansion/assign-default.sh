unset v
echo "${v:=assigned}"
echo "$v"
v=
echo "${v=nope}" "[$v]"
echo "${v:=yes}" "$v"
