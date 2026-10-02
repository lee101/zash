unset v
dir=/tmp/foo
echo ${v:-$dir/sub} ${v:-$(echo cmd)} ${v:-$((1+2))}
