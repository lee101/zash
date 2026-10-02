# cat: search
rg -n --sort path 'func \w+\(' src/go/pkg03 | head -30
