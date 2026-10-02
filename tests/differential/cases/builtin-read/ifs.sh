IFS=: read a b c <<< "x:y:z:w"
echo "$a|$b|$c"
