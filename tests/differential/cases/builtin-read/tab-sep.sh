IFS=$'\t' read -r a b c <<< $'x\ty\tz'
echo "$a|$b|$c"
