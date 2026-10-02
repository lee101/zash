true &
wait
kill -0 $! 2>/dev/null
echo $?
