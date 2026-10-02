d=$(pwd)
trap 'cd "$d"; echo restored' EXIT
cd dir
echo moved
