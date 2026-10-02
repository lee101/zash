# cat: search
find src -name '*.c' | xargs grep -l 'TODO' | wc -l
