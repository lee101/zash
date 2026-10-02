declare -A m=([k]=1)
[[ -v m[k] ]] && echo present
a=(1 2)
[[ -v a[1] ]] && echo idx1
[[ -v a[5] ]] || echo idx5-absent
