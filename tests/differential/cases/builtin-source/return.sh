cat > r.sh <<'XEOF'
echo before
return 3
echo after
XEOF
. ./r.sh
echo "status $?"
