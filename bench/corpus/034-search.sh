# cat: search
grep -rn 'import ' src/java | cut -d: -f1 | sort -u | head -10
