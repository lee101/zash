while IFS= read -r line; do
  case $line in
    \#*) continue;;
    '') continue;;
  esac
  echo "> $line"
done
