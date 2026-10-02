while IFS=, read -r a b c; do echo "$a|$b|$c"; done < data.csv
