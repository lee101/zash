# cat: control-flow
arr=(a b c d); echo ${#arr[@]} ${arr[2]} ${arr[@]:1:2}
