# cat: control-flow
for f in $(find src -name '*.c' | sort | head -10); do echo "$f $(wc -c < "$f")"; done | tail -3
