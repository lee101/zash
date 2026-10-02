( exit 1 ) & p1=$!
( exit 2 ) & p2=$!
wait $p1; echo $?
wait $p2; echo $?
