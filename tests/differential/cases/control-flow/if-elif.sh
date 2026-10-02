for n in 1 2 3 4; do
  if [ $n -eq 1 ]; then echo one
  elif [ $n -eq 2 ]; then echo two
  elif [ $n -eq 3 ]; then echo three
  else echo other
  fi
done
