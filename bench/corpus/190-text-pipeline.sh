# cat: text-pipeline
tail -n 200 logs/app.log | grep -c WARN
