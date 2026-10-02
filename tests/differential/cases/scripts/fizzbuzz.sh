for i in $(seq 1 15); do
  if (( i % 15 == 0 )); then echo FizzBuzz
  elif (( i % 5 == 0 )); then echo Buzz
  elif (( i % 3 == 0 )); then echo Fizz
  else echo $i; fi
done
