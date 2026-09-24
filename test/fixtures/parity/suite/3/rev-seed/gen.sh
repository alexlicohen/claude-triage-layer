#!/bin/sh
# Synthetic generator: a small module with three seeded defects (see key.json).
set -e
mkdir -p "$1"
cd "$1"
git init -q
cat > app.py <<'PY'
def mean(xs):
    total = 0
    for x in xs[1:]:
        total += x
    return total / len(xs)


def last(xs):
    return xs[len(xs)]


def is_even(n):
    return n % 2 == 1
PY
git add app.py
git commit -q -m "gen: app"
