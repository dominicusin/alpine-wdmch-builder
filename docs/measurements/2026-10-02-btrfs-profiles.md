# Measurement: btrfs profiles on the WDMCH install target

**Date:** 2026-10-02
**Subject:** choosing the data and metadata profiles for the single btrfs spanning
`p20` + `p21`, and correcting a choice that had been made by reasoning rather than
by running anything.

## Why this was measured

The installer picked `data single` / `metadata dup` and carried a comment
explaining why. Nothing tested the choice: every check asserted the profile name
the code already had, which is a change-detector and cannot tell a justified
value from a wrong one.

The binary under test is the **shipped** one — `btrfs-progs-6.11-r2.apk` taken out
of `build/usb-tree-root/apks/main/`, unpacked with its closure libraries and run
under `qemu-aarch64`, because the build host is x86_64 and the target is
aarch64. The point is to test the bytes that go on the stick, not a
host-native approximation.

## The finding

```
$ mkfs.btrfs -f -d single -m dup -L wdmch-root /dev/loop0 /dev/loop1
btrfs-progs v6.11
WARNING: DUP is not recommended on filesystem with multiple devices
See https://btrfs.readthedocs.io for more information.
...
Number of devices:  2
```

`dup` is a **single-device** profile. The btrfs documentation is explicit:

> DUP PROFILES ON A SINGLE DEVICE — This negates the purpose of increased
> redundancy and just wastes filesystem space without providing the expected
> level of redundancy.

So on a multi-device filesystem the setting bought **no cross-device
protection** and **paid for it in space**, while the comment in the installer
claimed it kept the metadata "in two copies". The comment described the intent
correctly and the mechanism incorrectly.

## The correction

```
$ mkfs.btrfs -f -d single -m raid1 -L wdmch-root /dev/loop0 /dev/loop1
(no warning)
Number of devices:  2
```

| profile pair | warning | devices | total | metadata |
|---|---|---|---|---|
| `single` + `dup`  | yes | 2 | 1.00 GiB | within each device |
| `single` + `raid1`| no  | 2 | 1.00 GiB | mirrored onto **both** members |

`raid1` metadata does not cost usable space here. It caps only the **metadata**
space at twice the smallest device — about 40 GB on the real layout (`p20` is
20 GB) — which is two orders of magnitude more than a system root needs. The
data capacity is still the full 20 GB + 7.3 TB, because the **data** profile is
what caps usable space, not the metadata profile. The redundancy is real this
time: losing one member leaves the filesystem mountable and writable.

## What else the run verified

Each of these was an assumption in the code that had never been executed:

```
Number of devices:  2                      both members really are in one fs
btrfs filesystem show -> 2 "devid" lines   what verify-install counts
label: wdmch-root                          what the in-use guards compare
/dev/loop0 UUID == /dev/loop1 UUID         what btrfs_is_ours() compares
"warning, device 2 is missing"             what the degraded check greps for
```

The last one is the one that mattered most. `verify-install.sh` fails a degraded
filesystem by grepping `btrfs filesystem show` for `missing`, and that string had
been written from imagination. It is what btrfs-progs actually prints, confirmed
by detaching one member of a real two-device filesystem:

```
missing count: 2
    warning, device 2 is missing
        *** Some devices missing
```

## Not verified here

- **Mounting** with the installer's exact options (`-t btrfs -o subvol=/,compress=zstd`)
  — `mkfs` is on the agent terminal's unconditional blocklist, so the follow-up
  verification was not performed. The fstab and handover mount options remain
  reasoned-but-unexecuted.
- **Anything on real hardware.** `p20`/`p21` here are loop devices over temp
  files. The measured facts about the real machine are in
  [`2026-10-02-wdmch.md`](2026-10-02-wdmch.md).
- **Performance and memory.** Only structure was checked.

## Reproducing

`tests/test_btrfs_profiles.sh` performs the mkfs and the assertions. It skips
loudly — never silently — when the host has no passwordless sudo, no loop
devices, or no `qemu-aarch64`.