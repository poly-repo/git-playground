#!/bin/sh
# fails if config.txt has a duplicate key
d=$(cut -d= -f1 "$(dirname "$0")/config.txt" | sort | uniq -d)
[ -z "$d" ] || { echo "duplicate key: $d"; exit 1; }
echo "check ok"
