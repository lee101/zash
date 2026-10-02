IFS=, read a b c d <<< "1,,3,"
echo "[$a][$b][$c][$d]"
