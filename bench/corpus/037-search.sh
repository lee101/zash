# cat: search
grep -rn 'Result<' src | cut -d: -f1 | sort -u | head -20
