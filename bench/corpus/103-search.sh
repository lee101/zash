# cat: search
find src/go -name '*.go' -exec grep -l Errorf {} + | head -3
