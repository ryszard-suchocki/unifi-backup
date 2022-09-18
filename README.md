# unifi-backup.sh

## Introduction
Unifi-backup.sh is a helper script that manages or conducts the process of backing up KVM Virtual Machines at an early stage. It is a kind of KVM Backup software that requires external tools to properly secure data as it does not backup files itself (by itself). `Unifi-backup.sh` only prepares VM files to backup. It uses something called "external snapshots", the snapshot method that can produce a VM disk image chain (base image with linked images (topmost image)) or produce a standalone image of each disk. You can read more about external snapshots and image chains in QEMU/Libvirt docs freely available on the internet. When the helper script finishes its task, you can back up the VM folder using any tool you prefer. In my case, I use Restic and Resticprofile. `Unifi-backup.sh` allow to the creation of full, diff, and incr types of backup. 

#### Short example

Main folder of VM is located at /storage/kvm/instances/MYVM/ # Here we have disk.1.qcow2, disk.2.qcow2, MYVM.xml (definition) etc.

When you want to back up VM using borg, restic, and kopia.io you should shut down your VM to provide consistency in data read-out, because in other cases VM disks are in constant write. Borg, Restic, kopia.io, and other programs are not able to track changes (what was written since the start of the backup). Writes on disks can occur in random places, so your image data is changing constantly. This can result in a broken disk image (making it unusable, if you create it in a dead simple, stupid way).

The recipe for this is an external snapshot that will produce an R/W image (topmost) and a R/O image (base). 

> !!! note 
> There is an additional mechanism that can provide filesystem quiesce  - Qemu Agent, that can call fs freeze and thaw to sync in memory pending writes > and provide crash consistent filesystem.
> !!!

Most filesystems are able to recover themselves from the "crash" state. 

R/W and R/O images allow us to read most of the data in the correct way (only R/O images should be read). 

The process looks like this:
 
- Call backup script for MyVM
- List block devices (disks) for MyVM (disk.1.qcow2 and disk.2.qcow2)
- Dump current configuration of MyVM (the main disk is disk.1.qcow2 and disk.2.qcow2)
- Invoke external snapshot command that produces disk.1.incr-YMD-HMS R/W image and disk.2.incr-YMD-HMS R/W image. disk.1.qcow2 and disk.2.qcow2 are now in kind of R/O mode. No writes will occur on them. 
- The script finishes its task

At this stage you can backup /storage/kvm/instances/MyVM/ via borg, restic, kopia.io

If you restore all files from a recent backup, you will also have disk.1.incr-YMD-HMS file, but it should be considered broken. When you restore the VM config (virsh define myvm.xml) you will have the correct configuration that points to the base disk (considered as R/O earlier).

What is most crucial borg, restic, and kopia.io knows what was backed up recently (based on timestamps), and there will be no need to read once again all R/O images - only a recent R/O image will be read out. So if you create quite often "incr" backup, only a small part needs to be read. 

When there is a lot of incr images (data traversal is taking a lot) you can consolidate "incr"s to "diff". Script will create a new file, pull data from all incr to itself (it knows the correct order of data that should be read out and written out to new file). So you will have one bigger diff file rather than a lots of smaller incremental. 

My strategy is to create a few (4-6 incr per day) INCRs, between 6 AM-8 PM, and at 9 PM create DIFF. The next days starts as BASE -> Diff -> Incr. 
On the next day, the old diff will be consolidated into a new diff (the intermediate incr will be also consolidated!). And then the weekend comes, so I can create a full backup as the I/O load is lower than during standard business hours.


Przygotowanie do tworzenia kopii QEMU/KVM. Działa tylko z plikami QCOW2.

```unifi-backup.sh
   ./unifi-backup.sh [-a <action> -m <mode>] [-b <directory>] [-q|-s <directory>] [-h] [-d] [-v] [-V] [-p] <domain name>
   
   Options:
      -a <action>
      -m <method>       Specified action mode/method: backup:[full|diff|incr|enable|disable|showchain] sync:[inplace|full|diff] maintenance:[enter|save|drop]
      -b <directory>    Copy previous snapshot/base image to the specified <directory> #not yet implemented
      -q                Use quiescence (qemu agent must be installed in the domain)
      -s <directory>    Dump domain status in the specified directory
      -d                Debug
      -h                Print usage and exit
      -v                Verbose
      -V                Print version and exit
      -p                Print files to backup

```

# Notify

```resticprofile
{{ .CurrentDir }}/notify send --config ./notify.yaml --alias smtp --title "Tytuł" --msg "Wiadomosc"
```

URL do wygenerowania przy użyciu [Shoutrrr](https://github.com/containrrr/shoutrrr) #generate

```notify.yaml
aliases:
  telegram:
    name: telegram-notify
    url: ""
  smtp:
    name: smtp-notify
    url: ""
```

# Generator

Skrypt, który ma za zadanie ułatwić tworzenie profili. Nie wykorzustuje dziedziczenia, przez co jest "samowystarczalny". Należy poprawić / dodać zmienne, a następnie wywołać skrypt z argumentami. Zakłada jedynie dziedziczenie po utworzonym profilu "incr".

```
$ ./unifi-generator.sh --help
  
   unifi-generator.sh version 1.0.0 - Ryszard Suchocki

   Usage:

   ./unifi-generator.sh [[-i <schedule>] [-d <schedule>] [-f <schedule>]] [-V] domain

   Options:
      -i|--incr <schedule>     Incremental type backup schedule
      -d|--diff <schedule>     Diffrential type backup schedule
      -f|--full <schedule>     Full type backup schedule
      -V                       Print version and exit

   Version Requirements:
      dasel	X.X (https://github.com/TomWright/dasel)

```
Przykład:

```
./unifi-generator.sh -i "Mon..Fri 8,12,16,20:00" -d "Mon..Fri 21:00" -f "Sat 20:00" MY-VM-NAME
```
# Bloby

Restic - restic is a backup program that is fast, efficient and secure - https://github.com/restic/restic [BSD 2]
Resticprofile - resticprofile is the missing link between a configuration file and restic backup - https://github.com/creativeprojects/resticprofile [GPL 3]
Dasel - Dasel (short for data-selector) allows you to query and modify data structures using selector strings - https://github.com/TomWright/dasel [MIT]
Shoutrrr- Notification library for gophers and their furry friends - https://github.com/containrrr/shoutrrr [MIT]
Systemd-timers - Better systemctl list-timers - https://github.com/dtan4/systemd-timers [MIT]


# Inspiracja i zapożyczenia:
https://github.com/dguerri/LibVirtKvm-scripts/blob/master/fi-backup.sh
