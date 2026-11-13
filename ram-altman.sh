#!/usr/bin/env bash
#
# ram-altman.sh - track RAM usage and, at most once a day, tell Sam Altman
# when this PC has RAM to spare.
#
# Usage:
#   ram-altman.sh            Log a sample and send the daily email if due
#   ram-altman.sh --status   Print current memory figures and exit
#   ram-altman.sh --dry-run  Print the email that would be sent and exit
#
# Cron (every 5 minutes):
#   */5 * * * * /path/to/ram-altman.sh
#
# launchd, for macOS (every 5 minutes):
#   see lol.ram-altman.plist
#
# How "used" is worked out:
#   used = MemTotal - MemAvailable
#
#   MemAvailable is the kernel's own estimate of how much memory can be handed
#   to new programs without swapping. It covers free memory plus the page cache
#   and slab memory that can be reclaimed, so cached RAM does not count as used.
#   It leaves out what can't really be reclaimed, such as tmpfs/shared memory,
#   which makes it more accurate than simply adding "free" and "cached" together.
#
# macOS has no /proc/meminfo, so there the same sum is built from vm_stat:
#   used = hw.memsize - (free + file-backed + purgeable pages)
#
#   File-backed pages are the page cache, and purgeable pages are memory that
#   apps have already said can be thrown away. Like free pages, both can be
#   handed to new programs without compressing or swapping anything. Together
#   those two are what Activity Monitor calls Cached Files, and what is left
#   over is what it lists as App Memory, Wired Memory and Compressed.

set -euo pipefail

# ----- Settings: fill these in -----------------------------------------------
RECIPIENT="${RAM_ALTMAN_TO:-}"             # Who receives the email
SENDER="${RAM_ALTMAN_FROM:-}"              # A real address you can send from
SENDER_NAME="${RAM_ALTMAN_FROM_NAME:-}"    # Display name, optional
THRESHOLD_PCT="${RAM_ALTMAN_THRESHOLD:-10}" # Email when available is above this
# -----------------------------------------------------------------------------

MEMINFO="${RAM_ALTMAN_MEMINFO:-/proc/meminfo}"
STATE_DIR="${RAM_ALTMAN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ram-altman}"
USAGE_LOG="$STATE_DIR/usage.csv"
LAST_SENT_FILE="$STATE_DIR/last_sent"
MAX_LOG_BYTES=$((10 * 1024 * 1024))   # Trim the log once it passes 10 MiB
LOG_LINES_TO_KEEP=50000

# cron and launchd start jobs with a short PATH. It often leaves out the
# directories sendmail lives in, and on a Mac the ones Homebrew puts msmtp in.
export PATH="$PATH:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

die() {
    printf 'ram-altman: %s\n' "$*" >&2
    exit 1
}

# Linux. Sets: total_kb, available_kb, free_kb, cache_kb
read_meminfo() {
    read -r total_kb available_kb free_kb cache_kb < <(
        awk '
            /^MemTotal:/      { total = $2 }
            /^MemFree:/       { free = $2 }
            /^MemAvailable:/  { available = $2; has_available = 1 }
            /^Buffers:/       { buffers = $2 }
            /^Cached:/        { cached = $2 }
            /^SReclaimable:/  { slab = $2 }
            /^Shmem:/         { shmem = $2 }
            END {
                cache = buffers + cached + slab - shmem
                if (cache < 0) cache = 0
                # Kernels older than 3.14 have no MemAvailable, so estimate it.
                if (!has_available) available = free + cache
                if (available > total) available = total
                print total + 0, available + 0, free + 0, cache + 0
            }
        ' "$MEMINFO"
    )

    (( total_kb > 0 )) || die "could not find MemTotal in $MEMINFO"
}

# macOS. Sets: total_kb, available_kb, free_kb, cache_kb
read_vm_stat() {
    local total_bytes
    total_bytes=$(sysctl -n hw.memsize 2> /dev/null || true)

    # vm_stat counts pages and prints each count with a trailing full stop,
    # which awk drops when it reads the field as a number.
    read -r total_kb available_kb free_kb cache_kb < <(
        vm_stat | awk -v total_bytes="$total_bytes" '
            /page size of [0-9]+ bytes/  { page_kb = $(NF - 1) / 1024 }
            /^Pages free:/               { free = $NF }
            /^Pages purgeable:/          { purgeable = $NF }
            /^File-backed pages:/        { file_backed = $NF; has_file_backed = 1 }
            END {
                # OS X before 10.9 does not report file-backed pages at all.
                if (!page_kb || !has_file_backed) exit 1
                total = total_bytes / 1024
                free_kb = free * page_kb
                cache_kb = (file_backed + purgeable) * page_kb
                available = free_kb + cache_kb
                if (available > total) available = total
                printf "%.0f %.0f %.0f %.0f\n", total, available, free_kb, cache_kb
            }
        '
    ) || die "could not find the page counts in vm_stat (needs macOS 10.9 or later)"

    (( total_kb > 0 )) || die "could not read hw.memsize from sysctl"
}

# Sets: total_kb, available_kb, used_kb, free_kb, cache_kb, available_pct
read_memory() {
    if [[ -r "$MEMINFO" ]]; then
        read_meminfo
    elif command -v vm_stat > /dev/null; then
        read_vm_stat
    else
        die "cannot read $MEMINFO or run vm_stat (this script needs Linux or macOS)"
    fi

    used_kb=$(( total_kb - available_kb ))
    available_pct=$(awk -v a="$available_kb" -v t="$total_kb" \
        'BEGIN { printf "%.1f", a * 100 / t }')
}

to_gib() {
    awk -v kb="$1" 'BEGIN { printf "%.1f GiB", kb / 1048576 }'
}

is_over_threshold() {
    (( available_kb * 100 > THRESHOLD_PCT * total_kb ))
}

print_status() {
    printf 'Total:      %s\n' "$(to_gib "$total_kb")"
    printf 'Used:       %s\n' "$(to_gib "$used_kb")"
    printf 'Available:  %s (%s%%)\n' "$(to_gib "$available_kb")" "$available_pct"
    printf '  Free:     %s\n' "$(to_gib "$free_kb")"
    printf '  Cache:    %s\n' "$(to_gib "$cache_kb")"
}

log_sample() {
    [[ -f "$USAGE_LOG" ]] ||
        echo 'timestamp,total_kb,used_kb,available_kb,available_pct' > "$USAGE_LOG"
    printf '%s,%s,%s,%s,%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        "$total_kb" "$used_kb" "$available_kb" "$available_pct" >> "$USAGE_LOG"

    if (( $(wc -c < "$USAGE_LOG") > MAX_LOG_BYTES )); then
        {
            head -n 1 "$USAGE_LOG"
            tail -n "$LOG_LINES_TO_KEEP" "$USAGE_LOG"
        } > "$USAGE_LOG.tmp"
        mv "$USAGE_LOG.tmp" "$USAGE_LOG"
    fi
}

# Prints the indexes 0 to count-1 in random order, one per line. Shuffled here
# in bash because shuf is a GNU tool, and macOS does not come with it.
shuffled_indexes() {
    local count=$1 i j swap
    local order=()
    for (( i = 0; i < count; i++ )); do
        order[i]=$i
    done
    for (( i = count - 1; i > 0; i-- )); do
        j=$(( RANDOM % (i + 1) ))
        swap=${order[i]}
        order[i]=${order[j]}
        order[j]=$swap
    done
    printf '%s\n' "${order[@]}"
}

# Deals out every option once, in random order, before any can come up again.
# Prints an index from 0 to count-1. A dry run changes nothing on disk.
pick() {
    local name=$1 count=$2 bag last next
    if [[ -n "${DRY_RUN:-}" ]]; then
        echo $(( RANDOM % count ))
        return
    fi

    bag="$STATE_DIR/bag_$name"
    if [[ ! -s "$bag" ]]; then
        shuffled_indexes "$count" > "$bag"
        # Stop the last pick of the old round opening the new one.
        last=$(cat "$bag.last" 2>/dev/null || true)
        if [[ "$(head -n 1 "$bag")" == "$last" ]] && (( count > 1 )); then
            { tail -n +2 "$bag"; head -n 1 "$bag"; } > "$bag.tmp"
            mv "$bag.tmp" "$bag"
        fi
    fi

    next=$(head -n 1 "$bag")
    tail -n +2 "$bag" > "$bag.tmp"
    mv "$bag.tmp" "$bag"
    echo "$next" > "$bag.last"

    # Covers the template lists being shortened after the bag was dealt.
    (( next < count )) || next=$(( RANDOM % count ))
    echo "$next"
}

compose_email() {
    local total available pct
    total=$(to_gib "$total_kb")
    available=$(to_gib "$available_kb")
    pct=$available_pct

    local subjects=(
        "Good news: we found some RAM"
        "Unused RAM detected in the wild"
        "RAM sighting on my PC"
        "$available of RAM, just sitting there"
        "You missed a spot"
        "Daily RAM census: some survived"
        "$pct% of my RAM remains at large"
        "Still not all of it, I'm afraid"
    )

    local bodies=(
        "I'm writing to report that you appear to have missed some. This PC has $total of RAM and $available of it ($pct%) is currently available. I assume this is an oversight."
        "A routine inspection of my PC found $available of unclaimed RAM out of $total. That's $pct% of the machine doing absolutely nothing. I thought you'd want to know before someone tries to train something on it."
        "Daily status report:

  Total RAM:     $total
  Available:     $available ($pct%)
  Threat level:  someone at OpenAI might notice"
        "Even with every browser tab I own open, $available of my $total of RAM is still available. I'm as surprised as you are."
        "Please don't be alarmed, but there is $available of RAM on my desk that isn't in a data centre. That's $pct% of what's installed here, and as far as I can tell it has no plans today."
        "Before you ask: yes, I counted the page cache as available. The kernel gives it back the moment anyone asks, which leaves $available of $total up for grabs."
        "Today's forecast for my PC: clear skies, light workloads and $pct% available memory. Expect $available of the installed $total to stay idle through the evening."
        "I hear RAM is hard to come by these days, so it feels a bit rude to be sitting on $available of it. Total installed: $total. It's not for sale, I just like knowing it's there."
        "I have a confession. I have $available of RAM that I'm not using, which is $pct% of the $total in this PC. I've told nobody but you and a cron job."
        "If $available of RAM sits idle in a PC and nobody allocates it, does it still count as capacity? Asking on behalf of the $pct% of my memory with nothing to do."
    )

    local signoffs=(
        "Yours in abundance,"
        "Regards from the last free RAM in the county,"
        "Hoarding responsibly,"
        "Stay allocated,"
        "Yours, with memory to spare,"
        "Kind regards,"
    )

    local subject_index body_index signoff_index
    subject_index=$(pick subject "${#subjects[@]}")
    body_index=$(pick body "${#bodies[@]}")
    signoff_index=$(pick signoff "${#signoffs[@]}")

    email_subject=${subjects[$subject_index]}
    email_body="Hi Sam,

${bodies[$body_index]}

${signoffs[$signoff_index]}
${SENDER_NAME:-A concerned RAM owner}

--
Sent automatically, at most once a day, by a small script on one PC.
Reply if you'd like it to stop."
}

render_message() {
    local from=$SENDER
    [[ -n "$SENDER_NAME" ]] && from="$SENDER_NAME <$SENDER>"
    printf 'From: %s\n' "$from"
    printf 'To: %s\n' "$RECIPIENT"
    printf 'Subject: %s\n' "$email_subject"
    printf 'Date: %s\n' "$(date -R)"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf 'Auto-Submitted: auto-generated\n'
    printf '\n%s\n' "$email_body"
}

send_email() {
    # Every Mac comes with a sendmail, whether or not anyone has set it up to
    # deliver anything, and it reports success as soon as a message is queued.
    # An msmtp is something its owner chose to install, and it only reports
    # success once a server has taken the message, so on macOS it goes first.
    if [[ "$(uname -s)" == Darwin ]] && command -v msmtp > /dev/null; then
        render_message | msmtp -t
    elif command -v sendmail > /dev/null; then
        render_message | sendmail -t -i
    elif command -v msmtp > /dev/null; then
        render_message | msmtp -t
    elif command -v mail > /dev/null; then
        printf '%s\n' "$email_body" | mail -s "$email_subject" "$RECIPIENT"
    else
        echo 'ram-altman: no sendmail, msmtp or mail command found' >&2
        return 1
    fi
}

main() {
    case "${1:-}" in
        --status)
            read_memory
            print_status
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            read_memory
            print_status
            if ! is_over_threshold; then
                echo "No email: available RAM is not above ${THRESHOLD_PCT}%."
                exit 0
            fi
            compose_email
            RECIPIENT=${RECIPIENT:-recipient-not-set@example.com}
            SENDER=${SENDER:-sender-not-set@example.com}
            printf '\n'
            render_message
            exit 0
            ;;
        -h|--help)
            sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        "")
            ;;
        *)
            die "unknown option: $1 (try --help)"
            ;;
    esac

    [[ -n "$RECIPIENT" ]] || die "RECIPIENT is not set"
    [[ -n "$SENDER" ]] || die "SENDER is not set"

    mkdir -p "$STATE_DIR"

    # Stop overlapping runs from both sending today's email.
    if command -v flock > /dev/null; then
        exec 9> "$STATE_DIR/lock"
        flock -n 9 || exit 0
    fi

    read_memory
    log_sample

    is_over_threshold || exit 0

    local today last_sent
    today=$(date +%F)
    last_sent=$(cat "$LAST_SENT_FILE" 2>/dev/null || true)
    [[ "$last_sent" != "$today" ]] || exit 0

    compose_email
    send_email || die "email failed to send; will try again on the next run"

    # Recorded only after a successful send, so a failure gets retried.
    echo "$today" > "$LAST_SENT_FILE"
}

main "$@"
