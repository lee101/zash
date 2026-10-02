# cat: control-flow
for f in data/small/*; do grep -c TODO "$f"; done | sort | uniq -c
