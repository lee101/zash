# cat: search
grep -rn 'throw new' src | cut -d: -f1 | sort -u | head -20
