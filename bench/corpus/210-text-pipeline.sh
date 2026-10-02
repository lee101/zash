# cat: text-pipeline
cat data/small/*.txt | sort | uniq -c | sort -rn | head -3
