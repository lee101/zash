# cat: text-pipeline
awk '{s+=$1} END{print s}' data/numbers.txt
