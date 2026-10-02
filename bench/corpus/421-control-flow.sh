# cat: control-flow
for f in data/small/*; do wc -l "$f"; done | tail -5
