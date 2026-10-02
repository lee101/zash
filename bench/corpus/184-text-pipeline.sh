# cat: text-pipeline
tail -n +2 data/users.csv | cut -d, -f5 | sort | uniq -c | sort -rn | head -3
