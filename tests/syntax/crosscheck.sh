#!/bin/bash
zash=${ZASH:-$(dirname "$0")/../../zig-out/bin/zash}
corpus=${1:-$(dirname "$0")/corpus.txt}
fail=0; total=0; msgfail=0
tmp=$(mktemp -d)
awk -v d="$tmp" 'BEGIN{n=0; f=sprintf("%s/%05d",d,n)} /^%%$/{close(f); n++; f=sprintf("%s/%05d",d,n); next} {print > f}' "$corpus"
for f in "$tmp"/[0-9]*; do
  total=$((total+1))
  src=$(cat "$f")
  bash -n "$f" >"$tmp/bout" 2>&1; b=$?
  [ $b -ne 0 ] && b=2
  "$zash" -n "$f" >"$tmp/zout" 2>&1; z=$?
  if [ $b -eq 2 ] && [ $z -eq 2 ] && ! cmp -s "$tmp/bout" "$tmp/zout"; then
    msgfail=$((msgfail+1))
    if [ -n "$MSGS" ]; then printf 'MSGDIFF\n%s\n--- bash\n%s--- zash\n%s\n' "$src" "$(cat "$tmp/bout")" "$(cat "$tmp/zout")"; fi
  fi
  if [ $b -ne $z ]; then
    fail=$((fail+1))
    printf 'MISMATCH bash=%s zash=%s\n%s\n---\n' "$b" "$z" "$src"
  fi
done
rm -rf "$tmp"
echo "total=$total mismatches=$fail message_diffs=$msgfail"
[ $fail -eq 0 ]
