# cat: text-pipeline
curl -s file://$PWD/data/words.txt | sort -u | wc -l
