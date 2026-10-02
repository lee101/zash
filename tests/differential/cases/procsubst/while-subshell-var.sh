while read -r l; do last=$l; done < <(printf 'a\nb\nc\n')
echo $last
