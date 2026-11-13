#!/usr/bin/env bash
# Exercises ram-altman.sh with simulated memory and a fake sendmail.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/ram-altman.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"

cat > "$work/bin/sendmail" <<EOF
#!/usr/bin/env bash
[[ -e "$work/fail" ]] && exit 75
cat >> "$work/outbox"
echo "=====END=====" >> "$work/outbox"
EOF
chmod +x "$work/bin/sendmail"

export PATH="$work/bin:$PATH"
export RAM_ALTMAN_TO=to@example.com RAM_ALTMAN_FROM=from@example.com
export RAM_ALTMAN_STATE_DIR="$work/state" RAM_ALTMAN_MEMINFO="$work/meminfo"

pass=0; fail=0
check() {
    if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok    $1"
    else fail=$((fail+1)); echo "FAIL  $1 (expected '$3', got '$2')"; fi
}
sent() { grep -c '^=====END=====$' "$work/outbox" 2>/dev/null || true; }
mem() { # total free available buffers cached slab shmem
    cat > "$work/meminfo" <<EOF
MemTotal:       $1 kB
MemFree:        $2 kB
${3:+MemAvailable:   $3 kB}
Buffers:        $4 kB
Cached:         $5 kB
SwapCached:     999999 kB
SReclaimable:   $6 kB
Shmem:          $7 kB
EOF
}

# Mostly page cache: little is free, but plenty is available.
mem 16000000 300000 9000000 200000 8000000 500000 100000
"$script"; check "cache counts as available: email sent" "$(sent)" 1
"$script"; "$script"; check "second and third run same day: no more email" "$(sent)" 1
check "used = total - available" "$(tail -n 1 "$work/state/usage.csv" | cut -d, -f3)" 7000000
check "three samples logged" "$(($(wc -l < "$work/state/usage.csv") - 1))" 3

# Next day, tight on memory.
echo 2000-01-01 > "$work/state/last_sent"
mem 16000000 300000 1000000 100000 800000 100000 100000
"$script"; check "6.2% available: no email" "$(sent)" 1

# Exactly 10% is not over 10%.
mem 16000000 300000 1600000 100000 800000 100000 100000
"$script"; check "exactly 10%: no email" "$(sent)" 1
mem 16000000 300000 1600001 100000 800000 100000 100000
"$script"; check "just over 10%: email sent" "$(sent)" 2

# A failed send is retried, and only recorded once it works.
echo 2000-01-01 > "$work/state/last_sent"
touch "$work/fail"
"$script" 2>/dev/null; check "failed send exits non-zero" "$?" 1
check "failed send not recorded" "$(cat "$work/state/last_sent")" 2000-01-01
rm "$work/fail"
"$script"; check "retry succeeds" "$(sent)" 3

# Old kernel with no MemAvailable: free + buffers + cached + slab - shmem.
# SwapCached in the fixture must not be picked up as Cached.
mem 16000000 1000000 "" 200000 3000000 500000 700000
out=$("$script" --status)
check "fallback estimate" "$(awk '/^Available:/ {print $2, $3}' <<<"$out")" "3.8 GiB"

# Variety: 10 bodies should all appear across 10 days, with no back-to-back repeat.
rm -f "$work/outbox" "$work/state"/bag_*
mem 16000000 300000 9000000 200000 8000000 500000 100000
for _ in $(seq 40); do echo 2000-01-01 > "$work/state/last_sent"; "$script"; done
awk 'BEGIN{RS="=====END=====\n"} NF{n=split($0,l,"\n"); for(i=1;i<=n;i++) if(l[i]=="Hi Sam,"){b=l[i+2]; print b}}' \
    "$work/outbox" > "$work/bodies"
# BSD wc pads its count with spaces, so $(( )) turns it back into a bare number.
check "all opening lines used" "$(( $(head -n 10 "$work/bodies" | sort -u | wc -l) ))" 10
check "no back-to-back repeat" "$(( $(uniq -d "$work/bodies" | wc -l) ))" 0

# Config errors.
RAM_ALTMAN_TO='' "$script" 2>/dev/null; check "missing recipient refused" "$?" 1

echo; echo "$pass passed, $fail failed"
echo; echo "--- real machine status ---"; RAM_ALTMAN_MEMINFO=/proc/meminfo "$script" --status
echo; echo "--- sample dry run ---"
mem 16000000 300000 9000000 200000 8000000 500000 100000
"$script" --dry-run
exit "$fail"
