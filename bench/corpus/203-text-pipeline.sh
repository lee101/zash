# cat: text-pipeline
diff <(head -5 data/words.txt) <(sed -n '2,6p' data/words.txt) | head -3
