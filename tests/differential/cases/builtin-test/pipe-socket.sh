[ -p /dev/stdin ] && echo pipe || echo notpipe
[ -S a.txt ] || echo notsock
[ -b a.txt ] || echo notblock
[ -c /dev/null ] && echo chardev
