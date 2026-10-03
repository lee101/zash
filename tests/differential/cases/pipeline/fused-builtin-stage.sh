echo hi | cat
echo "a b" | tr ' ' '\n' | sort -r | head -n 1
printf '%s\n' c a b | sort | tail -n 1
echo one | head -n 1; echo "st=${PIPESTATUS[*]}"
true | cat; echo "st=${PIPESTATUS[*]}"
false | cat; echo "st=${PIPESTATUS[*]}"
echo x | false; echo "st=${PIPESTATUS[*]}"
test -f nonexistent | cat; echo "st=${PIPESTATUS[*]}"
seq 1 3 | echo ignored | cat
echo big | /bin/cat | wc -c
pwd | wc -l
echo a | echo b | cat
printf '%d\n' notanumber 2>&1 | cat; echo "st=${PIPESTATUS[*]}"
x=1; echo $x | cat; echo "${x}"
echo "line1
line2" | grep -c line
set -o pipefail; false | echo hi; echo "pf=$?"
