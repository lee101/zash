echo 'x=sourced' > ss.sh
( . ./ss.sh; echo $x )
echo "[${x-unset}]"
