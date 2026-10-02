[[ -f a.txt && -r a.txt ]] && echo ok
[[ -d dir || -f dir ]] && echo ok2
[[ ! -e nonexistent ]] && echo ok3
