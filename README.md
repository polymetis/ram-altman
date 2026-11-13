# Ram-Altman

**A bash script that writes to Sam Altman once a day to report the RAM he missed.**

Read the sample emails at **[ram-altman.lol](https://ram-altman.lol)**, no install needed.

[![Website: ram-altman.lol](https://img.shields.io/badge/website-ram--altman.lol-0f5a43)](https://ram-altman.lol)
![Global DRAM allocation: quite terrible](https://img.shields.io/badge/global%20DRAM%20allocation-quite%20terrible-red)
![Utilization: maybe 5%](https://img.shields.io/badge/utilization-maybe%205%25-orange)
![Emails: 1 per day](https://img.shields.io/badge/emails-1%20per%20day-blue)
![Written in Bash, not Electron](https://img.shields.io/badge/written%20in-bash%2C%20not%20electron-brightgreen)

There is RAM in your computer. Right now. Just sitting there, in a *personal* computer, being personal.

You may have thought of this as "a computer working normally". On a recent episode of [Cheeky Pint](https://gizmodo.com/sam-altman-youre-completely-right-about-ram-im-sorry-for-the-confusion-heres-what-happened-2000835208), the CEO of OpenAI offered another view:

> "From a global allocation perspective, actually, it's quite terrible to have everybody have a bunch of the world's limited supply of DRAM sitting in their own computer"
>
> — Sam Altman

That RAM, he added, is ["being used maybe 5% of the time"](https://www.xda-developers.com/sam-altman-says-its-quite-terrible-that-people-have-ram-in-their-pcs-during-a-shortage/).

Which raised an obvious question for a certain kind of person: *surely someone should be monitoring this?*

So we wrote a script. If your machine has more than 10% of its RAM available, it sends one email a day to let Sam know. It seemed only fair. He can't fix the problem if nobody tells him where the RAM is.

## Features

- Tracks total, used and available RAM, plus your standing with the global allocation authorities
- Handles page cache correctly, which already puts it ahead of most arguments about RAM
- Sends at most one email per day, because we're hoarders, not animals
- Rotates 8 subject lines, 10 messages and 6 sign-offs, so the joke gets old at a carefully managed pace
- Logs every sample to CSV for when the auditors arrive
- Ships with 24 tests, more than the DRAM market has had sensible outcomes
- Is written in bash, as an Electron version would have solved the problem by using all the RAM

## A sample of today's correspondence

```text
Subject: You missed a spot

Hi Sam,

Please don't be alarmed, but there is 8.6 GiB of RAM on my desk that isn't in
a data centre. That's 56.2% of what's installed here, and as far as I can tell
it has no plans today.

Hoarding responsibly,
A concerned RAM owner

--
Sent automatically, at most once a day, by a small script on one PC.
Reply if you'd like it to stop.
```

The figures are real. They come from your machine. That's the worrying part.

## What counts as "used"?

```text
used = MemTotal - MemAvailable
```

`MemAvailable` is the kernel's own estimate of how much memory programs could claim without swapping. Free RAM counts as available. So does cache the kernel can reclaim. tmpfs and shared memory don't, because they can't simply be handed back.

Every sysadmin has spent years explaining that [Linux didn't eat your RAM](https://www.linuxatemyram.com/) and that free RAM is wasted RAM. It took decades for someone important to agree with the second part, and he'd like it shipped to him.

Strictly speaking, the page cache is doing useful work, so counting it as available is a generous concession to the other side. Think of it as a plea bargain.

On kernels older than 3.14, which have no `MemAvailable`, the script estimates it from free memory plus reclaimable cache. If you're on one of those, your RAM may be safe. Nobody's coming for that.

### On a Mac

macOS has no `/proc/meminfo` and no `MemAvailable`, so the script puts a figure of the same kind together from `vm_stat` and `sysctl hw.memsize`:

```text
used = total - (free + file-backed + purgeable)
```

File-backed pages are the page cache. Purgeable pages are memory that apps have already told macOS it may throw away. Neither holds anything that would have to be compressed or swapped before the memory could be reused, which is the idea behind `MemAvailable`.

It is a more generous figure than Linux's, though. Linux holds a reserve back, and macOS starts compressing app memory well before it has run the file cache down, so even a Mac that is swapping usually clears the 10% threshold. Sam can expect to hear from Mac owners on their bad days too.

If you check it against Activity Monitor, Cache is its Cached Files, and Used is its Memory Used minus purgeable memory, which Activity Monitor counts as used after already counting it as cached. Total is the RAM installed, as it is there. On Apple silicon that includes a slice the firmware keeps for itself before macOS starts, and it shows up as used.

`memory_pressure` will tell you a much bigger share of your memory is free. It counts everything macOS could push into the compressor or out to swap, including the apps you have open. That isn't idle RAM, it's a plan for your RAM, and we'd rather not give anyone ideas.

It's tested on macOS 15 and 26. On paper it goes back to 10.12: `vm_stat` has counted file-backed pages since 10.9, and `date -R`, which stamps the email, arrived in 10.12.

## Installation

You'll need Linux or macOS, bash, and a working `sendmail`, `msmtp` or `mail` command. Your RAM is assumed.

```bash
git clone https://github.com/IainKay/ram-altman.git
cd ram-altman
chmod +x ram-altman.sh test-ram-altman.sh

./ram-altman.sh --status    # see the evidence against you
./ram-altman.sh --dry-run   # preview an email without sending it
```

Example output, from a simulated machine that has confessed to everything:

```text
Total:      15.3 GiB
Used:       6.7 GiB
Available:  8.6 GiB (56.2%)
  Free:     0.3 GiB
  Cache:    8.2 GiB
```

To run it for real, add this to your crontab with `crontab -e`:

```cron
RAM_ALTMAN_TO=recipient@example.com
RAM_ALTMAN_FROM=you@example.com
RAM_ALTMAN_FROM_NAME=Your Name

*/5 * * * * /path/to/ram-altman.sh
```

It samples every five minutes and emails at most once a day. If a send fails, it tries again on the next run, because this message matters.

| Setting | What it does | Default |
| --- | --- | --- |
| `RAM_ALTMAN_TO` | Who receives the bad news | Required |
| `RAM_ALTMAN_FROM` | A real address you can send from | Required |
| `RAM_ALTMAN_FROM_NAME` | Your name, or your nom de RAM | Optional |
| `RAM_ALTMAN_THRESHOLD` | Email when available RAM is above this percentage (whole number) | `10` |
| `RAM_ALTMAN_STATE_DIR` | Where the log and state files live | `~/.local/state/ram-altman` |

### Running it on a Mac

A Mac would rather you used launchd than cron, so there's a job for it in [`lol.ram-altman.plist`](lol.ram-altman.plist):

```bash
cp lol.ram-altman.plist ~/Library/LaunchAgents/
# edit the copy: the full path to ram-altman.sh, and your addresses
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/lol.ram-altman.plist
```

It runs every five minutes while you're logged in, same as the crontab line, and anything the script complains about goes to `/tmp/ram-altman.err`. To call it off:

```bash
launchctl bootout gui/$(id -u)/lol.ram-altman
```

Two things are different from Linux:

- **Keep the script out of Desktop, Documents and Downloads.** macOS guards those folders, and a background job reaching into them can be refused with "Operation not permitted".
- **Every Mac has a `sendmail`, and it tells you what you want to hear.** It reports success as soon as a message is queued, then tries to deliver it straight from your Mac, which most networks and mail servers won't accept. The script can't see that, so it counts the day as done. Install `msmtp` instead (`brew install msmtp`) and give it a default account in `~/.msmtprc`: on a Mac the script uses it ahead of `sendmail`, and a send that fails gets retried. Whichever you use, point it at your own address first and see whether anything arrives.

## Audit yourself

Let it run for a while, then find out how your machine compares:

```bash
awk -F, 'NR>1 { used += $3; total += $2 }
  END { if (total) printf "Your RAM in use: %.1f%% (the claim: maybe 5%%)\n", used * 100 / total }' \
  ~/.local/state/ram-altman/usage.csv
```

Yes, share of memory in use isn't the same thing as share of time spent in use. If you came here to say that, welcome to Hacker News. We're glad you're here.

## Please be a good neighbour

One email a day from one person is a joke. Ten thousand of them is a denial-of-service attack with better material.

- **`--dry-run` is the best way to enjoy this.** It costs nothing and all the jokes are there.
- **This repo doesn't ship with anyone's email address,** and please don't add one.
- **Use your own real address.** No spoofing, and no running it across your server fleet.
- **If anyone asks you to stop, stop.** The footer of every email promises this, so keep the promise.

You can also point it at someone who will enjoy it, like the friend who has been waiting for DDR5 prices to come down.

## FAQ

**Does this help with the DRAM shortage?**
No.

**Is this a serious tool?**
The memory accounting is. The correspondence isn't.

**Does it work on macOS?**
Yes. A Mac has no `/proc/meminfo`, so it reads `vm_stat` instead. Your RAM is probably soldered down, which still makes you the hardest target in the global allocation programme.

**Why is the threshold 10%?**
Below that, your machine has suffered enough.

**Does running this use RAM?**
Briefly. It's then returned to the global pool, which is more than can be said for the rest of us.

**Can I run the tests without emailing anyone?**
Yes. `./test-ram-altman.sh` uses simulated memory and a fake `sendmail`. No inboxes are harmed.

**Can I see it without installing anything?**
Yes. [ram-altman.lol](https://ram-altman.lol) cycles through the real emails, with sample figures.

**What should I do with all this RAM?**
Open another browser tab. You've still got time.

## In fairness to Sam

Altman has since [said the remarks were taken out of context](https://gizmodo.com/sam-altman-youre-completely-right-about-ram-im-sorry-for-the-confusion-heres-what-happened-2000835208), writing:

> "i actually do want the world to have tons of memory and people to put as much as they want in their computers"

He [followed up](https://www.gadgetreview.com/sam-altman-says-he-wants-you-to-have-even-more-ram-not-less-changes-name-to-ram-altman) with "i want you to have so much ram" and "lets build more", and briefly changed his display name on X to Ram Altman, which is objectively excellent and is where this project gets its name.

The original remarks [came up in a discussion of running AI models locally](https://www.engadget.com/2303266/sam-altman-says-its-terrible-dram-computer/), and the utilization argument is a real one: servers really are busier than your desktop. We just think it's funnier to reply with cron.

Besides, if he wants you to have so much RAM, then this script isn't a complaint at all. It's a daily progress report.

## License

Free as in unallocated.
