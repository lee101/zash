# cat: control-flow
head -2000 data/words.txt | while read -r w; do echo ${#w}; done | sort -n | tail -1
