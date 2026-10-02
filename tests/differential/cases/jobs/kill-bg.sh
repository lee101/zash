sleep 5 &
p=$!
kill $p
wait $p 2>/dev/null
echo $?
