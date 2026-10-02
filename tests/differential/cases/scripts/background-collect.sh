for i in 1 2 3; do ( echo "job $i" > "job$i.out" ) & done
wait
cat job1.out job2.out job3.out
