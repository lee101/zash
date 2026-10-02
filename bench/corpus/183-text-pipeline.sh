# cat: text-pipeline
cut -d, -f1 data/users.csv | tail -n +2 | sort -n | tail -1
