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
