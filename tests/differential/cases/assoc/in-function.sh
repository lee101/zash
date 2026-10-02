declare -A g=([a]=1)
f() { echo ${g[a]}; g[b]=2; }
f
echo ${g[b]}
