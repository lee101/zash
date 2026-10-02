v=1
unset v
echo ${v:-default}
v=${v:-reassigned}
echo $v
