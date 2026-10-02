for f in src/*.c; do
  name=${f##*/}
  echo "${name%.c}: $(wc -l < "$f" | tr -d ' ') lines"
done
