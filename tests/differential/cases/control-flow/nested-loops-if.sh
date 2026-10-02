for i in 1 2 3; do
  if [ $i -eq 2 ]; then continue; fi
  for j in a b; do
    echo $i$j
  done
done
