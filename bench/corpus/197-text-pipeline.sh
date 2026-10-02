# cat: text-pipeline
cat data/words.txt | sort -u | head -5 | tr '\n' ' '; echo
