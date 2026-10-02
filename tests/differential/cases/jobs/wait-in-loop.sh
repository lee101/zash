for i in 1 2 3; do ( exit $i ) & done
wait
echo done
