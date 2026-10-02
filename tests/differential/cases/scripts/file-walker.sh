find . -type f -name '*.txt' | sort | while read -r f; do
  printf '%s %s\n' "$(wc -l < "$f" | tr -d ' ')" "$f"
done | head -8
