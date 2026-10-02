# cat: control-flow
n=$(git ls-files | wc -l); echo $((n / 2))
