# cat: text-pipeline
sed -n 's/^\(.*\)=\(.*\)$/\2 \1/p' data/kv.env | head -3
