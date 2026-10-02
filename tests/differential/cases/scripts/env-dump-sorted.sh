export ZA=1 ZB="two words"
env | grep '^Z[AB]=' | sort
