# unifi-backup.sh

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
