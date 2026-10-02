unset v
echo ${v:-a}b ${v:-"a b"} ${v:-'a b'} ${v:-a\ b}
