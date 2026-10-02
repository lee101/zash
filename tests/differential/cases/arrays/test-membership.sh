a=(x y z)
for v in y q; do
  found=no
  for e in "${a[@]}"; do [ "$e" = "$v" ] && found=yes; done
  echo $v $found
done
