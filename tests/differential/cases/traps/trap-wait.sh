trap 'echo interrupted' USR1
sleep 0.2 &
kill -USR1 $$
wait
echo done
