# cat: text-pipeline
# requires: logs/medium.log
tail -n 200 logs/medium.log | grep -c ERROR
