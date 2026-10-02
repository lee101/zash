# cat: search
grep -rn 'Errorf' src | cut -d: -f1 | sort -u | head -30
