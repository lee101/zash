# cat: git
git log --format=%s | sort | uniq -c | sort -rn | head -3
