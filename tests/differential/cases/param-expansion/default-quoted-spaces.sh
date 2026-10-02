unset v
set -- ${v:-a b c}
echo $#
set -- "${v:-a b c}"
echo $#
