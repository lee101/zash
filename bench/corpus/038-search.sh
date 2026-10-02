# cat: search
grep -rn 'IllegalArgument' src/java | cut -d: -f1 | sort -u | head -100
