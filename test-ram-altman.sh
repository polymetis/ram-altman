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
basename "\$0" > "$work/mailer"
cat >> "$work/outbox"
echo "=====END=====" >> "$work/outbox"
EOF
chmod +x "$work/bin/sendmail"
# The same fake answers to msmtp, so that whichever mailer the script reaches
# for, it never finds a real one. $work/mailer says which name it was called by.
cp "$work/bin/sendmail" "$work/bin/msmtp"

# The machine under test is a Linux one, wherever the tests are really run...
printf '#!/usr/bin/env bash\necho Linux\n' > "$work/bin/uname"
chmod +x "$work/bin/uname"

# ...except in on_mac, below, which puts this stand-in Mac first on the PATH.
mkdir -p "$work/macos"
cat > "$work/macos/vm_stat" <<EOF
#!/usr/bin/env bash
cat "$work/vm_stat.txt"
EOF
cat > "$work/macos/sysctl" <<EOF
#!/usr/bin/env bash
[[ "\$*" == "-n hw.memsize" ]] && cat "$work/memsize"
EOF
printf '#!/usr/bin/env bash\necho Darwin\n' > "$work/macos/uname"
chmod +x "$work/macos/vm_stat" "$work/macos/sysctl" "$work/macos/uname"

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
mac_mem() { # total_bytes page_bytes free purgeable file_backed
    echo "$1" > "$work/memsize"
    # Every other line is a bystander that must not end up in the sums.
    cat > "$work/vm_stat.txt" <<EOF
Mach Virtual Memory Statistics: (page size of $2 bytes)
Pages free:                               $3.
Pages active:                            400000.
Pages inactive:                          355000.
Pages speculative:                        10000.
Pages throttled:                              0.
Pages wired down:                        150000.
Pages purgeable:                          $4.
Pages purged:                           9999999.
File-backed pages:                       $5.
Anonymous pages:                         515000.
Pages stored in compressor:              300000.
Pages occupied by compressor:            123576.
EOF
}
on_mac() { # runs the script where there is no meminfo, only vm_stat and sysctl
    PATH="$work/macos:$PATH" RAM_ALTMAN_MEMINFO="$work/no-meminfo" "$script" "$@"
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
check "sendmail is tried before msmtp" "$(cat "$work/mailer")" sendmail

# Old kernel with no MemAvailable: free + buffers + cached + slab - shmem.
# SwapCached in the fixture must not be picked up as Cached.
mem 16000000 1000000 "" 200000 3000000 500000 700000
out=$("$script" --status)
check "fallback estimate" "$(awk '/^Available:/ {print $2, $3}' <<<"$out")" "3.8 GiB"

# macOS has no /proc/meminfo: the figures come from vm_stat and sysctl instead.
# A 16 GiB Apple Silicon Mac, which counts its memory in 16 KiB pages.
mac_mem 17179869184 16384 10000 15000 250000
out=$(on_mac --status)
check "macOS: available = free + file-backed + purgeable" \
    "$(awk '/^Available:/ {print $2, $3, $4}' <<<"$out")" "4.2 GiB (26.2%)"
check "macOS: purgeable counts as cache, speculative not as free" \
    "$(awk '/Free:/ {free = $2} /Cache:/ {cache = $2} END {print free, cache}' <<<"$out")" "0.2 4.0"
# The awk on macOS follows the locale, and a decimal comma would split the CSV.
check "macOS: figures keep their full stop in a comma locale" \
    "$(LC_ALL=de_DE.UTF-8 on_mac --status | awk '/^Available:/ {print $2, $3, $4}')" "4.2 GiB (26.2%)"

# The same memory in 4 KiB pages, as on an Intel Mac, gives the same figures.
mac_mem 17179869184 4096 40000 60000 1000000
check "macOS: page size is read, not assumed" \
    "$(on_mac --status | awk '/^Available:/ {print $2, $3, $4}')" "4.2 GiB (26.2%)"

echo 2000-01-01 > "$work/state/last_sent"
on_mac; check "macOS: email sent" "$(sent)" 4
check "macOS: used = total - available" \
    "$(tail -n 1 "$work/state/usage.csv" | cut -d, -f2-4)" "16777216,12377216,4400000"
# Every Mac has a sendmail, set up or not, so an msmtp is preferred there.
check "macOS: msmtp is tried before sendmail" "$(cat "$work/mailer")" msmtp

# Before macOS 15 the free count could wrap round to four billion pages just as
# free memory ran out. Believing it would report a full Mac as an empty one.
mac_mem 17179869184 16384 4294967196 15000 250000
check "macOS: a wrapped free count is read as none free" \
    "$(on_mac --status | awk '/^Available:/ {print $2, $3, $4}')" "4.0 GiB (25.3%)"

# A vm_stat without the page counts is refused, not guessed at.
echo "Mach Virtual Memory Statistics: (page size of 4096 bytes)" > "$work/vm_stat.txt"
on_mac --status 2>/dev/null; check "macOS: vm_stat without page counts refused" "$?" 1

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
