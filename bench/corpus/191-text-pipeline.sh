# cat: text-pipeline
tail -n 1000 logs/app.log | cut -d' ' -f2 | sort | uniq -c
