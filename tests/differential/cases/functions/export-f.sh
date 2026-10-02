f() { echo exported; }
export -f f
bash -c 'f'
