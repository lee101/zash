# cat: text-pipeline
# requires: logs/huge.log
tail -n 200 logs/huge.log | grep -c ERROR
