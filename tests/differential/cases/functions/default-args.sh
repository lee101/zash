f() { local a=${1:-def1} b=${2:-def2}; echo $a $b; }
f
f x
f x y
