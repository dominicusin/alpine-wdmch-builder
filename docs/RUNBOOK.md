# Runbook: first boot and acceptance

Applies after `install-alpine` has written the single btrfs spanning `p20` +
`p21` (label `wdmch-root`) and the box has been rebooted. Read `ROADMAP.md` for
the staged validation this follows.

This document has two parts with very different confidence, and the
difference matters:

- **Part 1 is verified.** It is a script that exists and is exercised.
- **Part 2 is a sizing and decision aid, not a recipe.** The restoration
  surface is 21 FidoNet units plus PostgreSQL and Docker. Writing 21
  untested `systemctl` commands would produce a second copy of a document
  nobody can verify, which is the exact failure mode this repository spent
  the last several releases removing.

---

## Part 1 — Acceptance (verified, scripted)

### 1.1 Reach the box

The rescue image and the installed system both use dropbear with
public-key authentication only. There is no password login.

```bash
ssh <user>@<address>
```

If the address is unknown, the rescue banner prints it.

### 1.2 Run the health check

`install-alpine` placed it on the target:

```bash
verify-install
```

It checks, and names the failing line if something is wrong:

| Check | What a pass means |
|---|---|
| init is PID 1 | The system is actually running, not a rescue shell that never handed over |
| `/` is btrfs, label `wdmch-root` | The installer wrote the filesystem it said it would |
| btrfs spans 2 devices | The install really used both p20 and p21, not one |
| btrfs is not degraded | No member device is missing — the failure that boots fine and then fails on write |
| `/` is mounted rw | The root filesystem is not read-only |
| internal disk has ≥20 partitions | **The factory GPT survived.** This is the safety property |
| `/boot/Image` present | The kexec handoff has something to load |
| offline install complete | busybox, openrc, openrc-init, dropbear, ifupdown-ng, mdev-conf are in the package database |
| `eth0` has an address | Networking works |
| dropbear is listening | SSH works |

Exit status is non-zero on any failure, so it is safe to gate a script on.

The GPT line deserves emphasis. If the partition count dropped, something
wrote a partition table and the box is now in a state the project exists to
avoid. Stop and read `docs/RECOVERY.md` before doing anything else.

### 1.3 Optional: exercise the rollback

Before restoring anything real, prove the escape hatches work while the
stakes are low:

```bash
# return to rescue instead of handing over to Alpine
touch /path/to/stick/norescue
```

Remove it (or leave the stick out) to hand over normally. The 20-second
window after boot allows cancelling the handover from the console.

Also confirm the firmware table backup exists:

```bash
ls -l /root/wdmch-fw-table-backup.bin
```

It is not the rollback — the untouched `p19 SYSTEM_A` and the preserved GPT
are. It is a copy of the one partition the installer reads before writing.

### 1.4 One thing to know about the handoff

The handoff script carries a safety net: if the installed system has no
`authorized_keys`, it copies the **rescue** key in, so you cannot lock
yourself out of a device whose only access is SSH and a serial console.

`install-alpine` now refuses to complete without a key, so this only fires if
a key was deliberately removed after installation. When it does, the console
says so in capitals and the rescue key becomes a **persistent credential on
the internal disk** — it stays there even after the stick is pulled.

If that is not what you want, remove it after the first boot:

```bash
rm /root/.ssh/authorized_keys
```

Then install your own key and reload dropbear. The trade is deliberate: an
extra key is recoverable, a locked-out unit on a NAS is not.

---

## Part 2 — Restoration: size it before you start

### 2.1 What has to come back

Taken from the Ansible estate that currently manages this machine, not
assumed. 21 FidoNet units, of which 6 are timers:

```
fido2web            fidonet-backup         fidonet-index
fido-flightrec.timer fidonet-backup-offsite  fidonet-inotify
fido-index          fidonet-bbs            fidonet-rss
fidonet-admin       fidonet-bootcheck      fidonet-sqpack
fidonet-areastat    fidonet-diskguard.timer fidonet-target
                    fidonet-failover.timer  fidonet-telegram
                    fidonet-hatch-stats    fidonet-heal.timer
                    fidonet-hpucode        fidonet-search.timer
                                              fidonet-spoolclean.timer
```

Plus, from the same estate: PostgreSQL, Docker, node_exporter, healthchecks
integration, and the cron jobs under `/etc/cron.d/fidonet*`.

Data lives under `/var/spool/fido` (`866_u8.chs`, `data/archive_ts`,
`data/inn-gw.state`, `dupe/`, `etc/`) with secrets in `/etc/fido`, including
`inn-gateway.env`.

### 2.2 The decisive question comes first

Before restoring anything: **does this fit, and is it worth it?**

Two measurements decide it, and `tools/preflight.sh` on the *current*
Debian system produces both:

- **Size.** What does the current estate occupy on disk, and what is
  available in `p20`? A 21-unit FidoNet node with PostgreSQL and archived
  traffic history is not a small payload. If it does not fit, no amount of
  restoration effort matters.
- **Resources.** Actual memory and CPU under real load. Alpine is smaller,
  but the current system demonstrably runs the workload; that is a cost the
  migration spends to buy a benefit that has not been demonstrated to exist.

`STRATEGY.md` §3 argues that if the motivation is tidiness, the migration
costs more than it returns. The measured service count strengthens that
sharply: this is not a handful of services, and **FidoNet has no native
Alpine packaging** — it is installed from Debian packages, so every binary
arrives as a foreign artifact rather than a package-manager entry.

That is the single most important fact in this document. It changes the
shape of the work: the effort is in *foreign binaries and manual service
assembly*, not in configuration.

### 2.3 If the decision is to proceed

Order matters, and the ordering principle is **data before services**:

1. **Bring the data across first** — `/var/spool/fido` and `/etc/fido` are
   the irreplaceable part. Services can be recreated; an archive cannot.
2. **User and permissions** — the `fido` user and group must own the spool
   before any daemon starts, or the first run creates root-owned files in
   the tree and later runs fail on them.
3. **Secrets** — `inn-gateway.env` and `/etc/fido/config`. Do not
   reconstruct these from memory; copy them.
4. **The binary distribution** — FidoNet software is not in Alpine's
   repositories. Fetch it, pin it, and record what it is.
5. **Timers last** — the six timers (backup, diskguard, failover, heal,
   search, spoolclean) can fire immediately and act on a half-restored
   tree. Enable them once the services above are healthy.

### 2.4 Known traps in the restoration

These are not hypothetical; they are properties of this specific setup.

- **CUPS and macOS clients.** Debian's CUPS announces `_ipps._tcp` over
  DNS-SD even with `SSLOptions None`, and macOS rejects a self-signed
  certificate. The fix is `BrowseLocalProtocols none` in `cupsd.conf` plus a
  hand-written avahi service advertising only `_ipp._tcp:631`. Without
  both, printers simply do not appear.
- **mosh.** mosh is UDP. If a Webmin nftables profile is active on the box,
  SSH works while mosh fails, and the failure looks like a mosh bug. The
  profile's input chain drops UDP with a terminal policy, so neither a
  custom table nor a later accept rule helps — the accept has to be
  *inserted* into that chain, and it must survive the flush that
  `flush ruleset` performs.
- **Alpine networking.** Alpine ships no `ifupdown` config by default.
  `ifupdown-ng` is installed by the offline closure, but `/etc/network/interfaces`
  has to exist. Without it `eth0` never comes up and the SSH check in
  `verify-install` will say so.

---

## Part 3 — What to record afterwards

Whatever is decided, record the result while it is fresh:

- the exact `verify-install` output from the first boot;
- the serial console output (this is the only record of the boot path that
  no automated check has ever produced);
- the measured size and memory figures from `tools/preflight.sh`;
- the decision itself, and the reasoning, in `STRATEGY.md` §3.

The serial output is worth capturing even if everything works. It is the
evidence that would let the next person skip a hardware session entirely.
