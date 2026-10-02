echo hello | tee >(cat > ps.out) > /dev/null
sleep 0.1
cat ps.out
