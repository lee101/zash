# cat: text-pipeline
cut -d, -f5 data/users.csv | sort | uniq -c | sort -rn | head
