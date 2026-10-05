seq 1 20 | sed -n '5,8p'
seq 1 20 | sed 's/1/one/g' | head -n 3
printf 'a b\nc d\n' | sed -E 's/(\w) (\w)/\2 \1/' | tr a-z A-Z
yes | sed 3q | wc -l
printf 'x\ny\nz' | sed '$!N;s/\n/+/' | cat
seq 1 5 | sed -n '$='
printf 'a\nb\n' | sed 'a tail' | grep -c tail
