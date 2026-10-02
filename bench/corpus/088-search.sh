# cat: search
find src -name '*.js' | xargs grep -l 'TODO' | wc -l
