# cat: git
wc -l $(git ls-files src/c | head -30) | tail -1
