# cat: text-pipeline
# requires: logs/huge.log
tail -n 1000 logs/huge.log | cut -d' ' -f2 | sort | uniq -c
