for i in 1 2 3; do
  row=
  for j in 1 2 3; do row="$row$((i*j)) "; done
  echo "${row% }"
done
