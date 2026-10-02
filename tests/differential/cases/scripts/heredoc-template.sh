name=World
n=3
cat <<EOF
Hello, ${name}!
You have $n new $( [ $n -eq 1 ] && echo message || echo messages ).
Total: $((n * 2))
EOF
