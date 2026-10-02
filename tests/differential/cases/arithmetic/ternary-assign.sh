a=1
b=$(( a ? 10 : 20 ))
echo $b
(( a ? (b=3) : (b=4) )); echo $b
