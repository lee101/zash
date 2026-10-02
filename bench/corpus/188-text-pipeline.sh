# cat: text-pipeline
awk 'NR%1000==0' data/words.txt | head -5
