printf 'a\nb' | while read -r l || [ -n "$l" ]; do echo "[$l]"; done
