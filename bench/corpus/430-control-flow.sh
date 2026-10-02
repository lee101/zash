# cat: control-flow
for f in src/ts/svc01/*; do [ -s "$f" ] && echo "$f"; done | wc -l
