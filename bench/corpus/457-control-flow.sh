# cat: control-flow
for f in $(find src -name '*.go' | sort | head -10); do echo "$f $(wc -c < "$f")"; done | tail -3
