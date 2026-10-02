declare -A m=([k]=)
echo ${m[k]+set} ${m[nope]+set}
[[ -v m[k] ]] && echo present
[[ -v m[nope] ]] || echo absent
