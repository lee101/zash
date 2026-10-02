for x in apple banana cherry date; do
  case $x in
    a*) echo "$x A";;
    b*|c*) echo "$x BC";;
    *) echo "$x other";;
  esac
done
