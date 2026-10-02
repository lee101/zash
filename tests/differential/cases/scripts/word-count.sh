tr -cs 'a-z' '\n' < words.txt | sort | uniq -c | sort -k1,1nr -k2 | head -3
