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

# Inspiracja i zapożyczenia:
https://github.com/dguerri/LibVirtKvm-scripts/blob/master/fi-backup.sh
