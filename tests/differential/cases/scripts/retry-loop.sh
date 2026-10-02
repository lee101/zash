attempt=0
until [ $attempt -ge 3 ]; do
  attempt=$((attempt+1))
  echo "attempt $attempt"
  [ $attempt -eq 2 ] && break
done
echo "stopped at $attempt"
