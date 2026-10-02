# cat: text-pipeline
sort data/words.txt | uniq -c | sort -rn | head -10
