# cat: text-pipeline
# requires: logs/medium.log
cut -d' ' -f2 logs/medium.log | head -100000 | sort | uniq -c | sort -rn
