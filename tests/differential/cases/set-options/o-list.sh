set -o | grep -E '^(errexit|nounset|pipefail|noglob|noclobber) ' | tr -s ' \t' ' '
