# cat: text-pipeline
# requires: logs/huge.log
cut -d' ' -f2 logs/huge.log | head -100000 | sort | uniq -c | sort -rn
