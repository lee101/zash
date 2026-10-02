# cat: text-pipeline
# requires: logs/medium.log
tail -n 1000 logs/medium.log | cut -d' ' -f2 | sort | uniq -c
