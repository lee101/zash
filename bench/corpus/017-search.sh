# cat: search
rg -n --sort path -g '*.go' 'func ' | head -3
