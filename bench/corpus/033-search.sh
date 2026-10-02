# cat: search
grep -rn 'HACK' src/c | cut -d: -f1 | sort -u | head -3
