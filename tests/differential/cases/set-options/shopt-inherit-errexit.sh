set -e
shopt -s inherit_errexit
x=$(false; echo no)
echo "[$x]"
