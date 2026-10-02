# cat: control-flow
for f in data/small/*; do [ -s "$f" ] && echo "$f"; done | wc -l
