mapfile -t lines < a.txt
echo ${#lines[@]} "${lines[0]}" "${lines[3]}"
