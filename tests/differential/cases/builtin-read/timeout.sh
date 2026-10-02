read -t 0.05 x < <(sleep 1)
echo "status $(( $? > 128 ? 1 : 0 ))"
