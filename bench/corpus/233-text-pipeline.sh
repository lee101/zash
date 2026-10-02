# cat: text-pipeline
# requires: logs/huge.log
sed -n '100000,100004p' logs/huge.log
