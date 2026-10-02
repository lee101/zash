mapfile lines < a.txt
printf '%s' "${lines[0]}" | od -c | head -1
