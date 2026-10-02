# cat: control-flow
for f in src/java/com/example/pkg02/*; do [ -s "$f" ] && echo "$f"; done | wc -l
