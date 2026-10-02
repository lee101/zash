stack=()
push() { stack+=("$1"); }
pop() { local n=${#stack[@]}; echo "${stack[n-1]}"; unset "stack[n-1]"; }
push a; push b; push c
pop; pop
echo ${#stack[@]}
