mapfile -t l < <(printf 'p\nq\n')
echo ${#l[@]} ${l[1]}
