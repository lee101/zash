for choice in start stop restart status bogus; do
  case $choice in
    start|restart) echo "starting ($choice)";;
    stop) echo stopping;;
    status) echo running;;
    *) echo "unknown: $choice";;
  esac
done
