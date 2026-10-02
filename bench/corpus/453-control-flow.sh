# cat: control-flow
for f in src/js/comp02/*; do [ -s "$f" ] && echo "$f"; done | wc -l
