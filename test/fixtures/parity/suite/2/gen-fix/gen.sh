#!/bin/sh
# Synthetic generator: a one-file repo with a misspelled greeting.
set -e
mkdir -p "$1"
cd "$1"
git init -q
printf '#!/bin/sh\necho helo\n' > greet.sh
git add greet.sh
git commit -q -m "gen: greet"
