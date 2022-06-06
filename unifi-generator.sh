#!/bin/bash

VERSION="1.0.0"
APP_NAME="resticprofile-generator.sh"
DASEL_BIN=./dasel

function print_usage() {
   [ -n "$1" ] && (echo "" ; echo "$1")
   cat <<EOU
  
   $APP_NAME version $VERSION - Ryszard Suchocki

   Usage:

   $0 [[-i <schedule>] [-d <schedule>] [-f <schedule>]] [-V] domain

   Options:
      -i|--incr <schedule>     Incremental type backup schedule
      -d|--diff <schedule>     Diffrential type backup schedule
      -f|--full <schedule>     Full type backup schedule
      -V                Print version and exit

   Version Requirements:
      dasel	X.X (https://github.com/TomWright/dasel)

EOU
}


function new_config_file(){
    touch "${DOMAIN}.yaml"
    rm "${DOMAIN}.yaml"
    touch "${DOMAIN}.yaml"
}

function yml_get_base(){
	echo "${BASE}${SEPARATOR}${BACKUP_LEVEL}"
}

function yml_write(){
    WHERE=$1
    WHAT=$2
    if [ "$WHAT" = "true" ] || [ "$WHAT" = "false" ]; then
        #		echo "$WHAT recognized as bool"
        $DASEL_BIN put bool -f "${DOMAIN}.yaml" "$(yml_get_base).${WHERE}" "${WHAT}"
        elif [ -n "$WHAT" ] && [ "$WHAT" -eq "$WHAT" ] 2>/dev/null; then
        #		echo "$WHAT recognized as number"
        $DASEL_BIN put int -f "${DOMAIN}.yaml" "$(yml_get_base).${WHERE}" "${WHAT}"
    else
        #		echo "$WHAT recognized as string"
        $DASEL_BIN put string -f "${DOMAIN}.yaml" "$(yml_get_base).${WHERE}" "${WHAT}"
    fi
}

function yml_write_global(){
    local BASE="$3" #subsection
    local SEPARATOR=""
    local BACKUP_LEVEL=""
    yml_write "$1" "$2"
}

TEMP=$(getopt -n "$APP_NAME" -o i:d:f:hV --long incr:,diff:,full:,help,version -- "$@")
if [ $? != 0 ] ; then
    echo "Failed parsing options." >&2 ;
    exit 1 ;
fi

eval set -- "$TEMP"
while true; do
    case "$1" in
        -i|--incr)
            SCHEDULE_MAIN="$2"
            shift;shift
        ;;
        -d|--diff)
            SCHEDULE_DIFF="$2"
            shift;shift
        ;;
        -f|--full)
            SCHEDULE_FULL="$2"
            shift;shift
        ;;
        -h|--help)
            print_usage
            shift
            exit 0
        ;;
        -V|--version)
            echo "$APP_NAME version $VERSION"
            shift
            exit 0
        ;;
        -- ) shift; break ;;
        * ) break ;;
    esac
done

if [ -z $1 ]; then
	print_usage "Domain name is required!"
	exit 1
fi

DOMAIN="$1"
BASE="${DOMAIN}"
SEPARATOR="-"

# REPOSITORY vars
NAS01_REPO="sftp://user@server:22/Backup/Restic"
NAS02_REPO="sftp://user@server2:22/Restic"

# NOTIFICATION vars
NOTIFY='./notify send --config notify.yaml --alias telegram'
NOTIFY_OK='"🟢 SUCCESS | \"$DOMAIN (vm) @ $(hostname)\" - Restic - Profile \"$PROFILE_NAME\" command \"$PROFILE_COMMAND\" - SUCCESS"'
NOTIFY_NG='"🔴 FAIL | \"$DOMAIN (vm) @ $(hostname)\" - Restic - Profile \"$PROFILE_NAME\" command \"$PROFILE_COMMAND\" - FAILED"'
MSG_OK='"Plugin: KVM, source: $DOMAIN; profile \"$PROFILE_NAME\" command \"$PROFILE_COMMAND\" finished OK"'
MSG_NG='"Plugin: KVM, source: $DOMAIN; Profile \"$PROFILE_NAME\" command \"$PROFILE_COMMAND\" finished NG. Details about error: \"$ERROR_STDERR\""'


# Generate new config file / overwrite
new_config_file

# global section
yml_write_global 'restic-binary' '{{ .ConfigDir }}/restic' 'global'
yml_write_global 'scheduler' 'systemd' 'global'
yml_write_global 'default-command' "snapshots" 'global'
yml_write_global 'initialize' 'false' 'global'
yml_write_global 'restic-stale-lock-age' '2h' 'global'
yml_write_global 'restic-lock-retry-after' '15m' 'global'

# default section
yml_write_global 'env.[].tmp'  '/tmp' 'default'
yml_write_global 'backup.schedule-log' '{{ .ConfigDir }}/logs/{{ .Profile.Name }}.log' 'default'


#####################################################################################
#####################################################################################
#####################################################################################
##############                    CONFIG section                #####################
#####################################################################################
#####################################################################################
#####################################################################################

BACKUP_LEVEL="incr"

yml_write_global "${BACKUP_LEVEL}" "$(yml_get_base)" 'groups'

yml_write 'initialize' true
yml_write 'repository' "$NAS01_REPO/${DOMAIN}"
yml_write 'password-file' "./keys.d/${DOMAIN}.key"

yml_write 'lock' "{{ .ConfigDir }}/${DOMAIN}.lock"

yml_write 'env.[].backup_level' "$BACKUP_LEVEL"
yml_write 'env.[].domain' "$DOMAIN"
yml_write 'backup.source.[]' "/storage/kvm/instances/${DOMAIN}"
yml_write 'backup.schedule' "${SCHEDULE_MAIN}"
yml_write 'backup.run-before' '{{ .ConfigDir }}/unifi-backup.sh -a backup -m $BACKUP_LEVEL $DOMAIN'
yml_write 'backup.tag.[]' "${DOMAIN}"
yml_write 'backup.tag.[]' "kvm"
yml_write 'backup.tag.[]' "${BACKUP_LEVEL}"

yml_write 'run-after.[]' "${NOTIFY} --title ${NOTIFY_OK} --msg ${MSG_OK}"
yml_write 'run-after-fail.[]' "${NOTIFY} --title ${NOTIFY_NG} --msg ${MSG_NG}"

yml_write 'retention.after-backup' true
yml_write 'retention.before-backup' false
yml_write 'retention.compact' true
yml_write 'retention.prune' true
yml_write 'retention.host' false
yml_write 'retention.path' true
yml_write 'retention.keep-hourly' 1
yml_write 'retention.keep-last' 3
yml_write 'retention.keep-daily' 14
yml_write 'retention.keep-weekly' 12
yml_write 'retention.keep-monthly' 6
yml_write 'retention.keep-yearly' 1
yml_write 'retention.tag.[]' "${DOMAIN}"
yml_write 'retention.tag.[]' "kvm"
yml_write 'retention.tag.[]' "${BACKUP_LEVEL}"

TMP="$BACKUP_LEVEL"
BACKUP_LEVEL="diff"
yml_write_global "${BACKUP_LEVEL}" "$(yml_get_base)" 'groups'

yml_write 'inherit' "${BASE}${SEPARATOR}${TMP}"
yml_write 'env.[].backup_level' "$BACKUP_LEVEL"
yml_write 'env.[].domain' "$DOMAIN"
yml_write 'backup.schedule' "${SCHEDULE_DIFF}"
yml_write 'backup.tag.[]' "${DOMAIN}"
yml_write 'backup.tag.[]' "kvm"
yml_write 'backup.tag.[]' "${BACKUP_LEVEL}"
yml_write 'retention.tag.[]' "${DOMAIN}"
yml_write 'retention.tag.[]' "kvm"
yml_write 'retention.tag.[]' "${BACKUP_LEVEL}"

TMP="$BACKUP_LEVEL"
BACKUP_LEVEL="full"
yml_write_global "${BACKUP_LEVEL}" "$(yml_get_base)" 'groups'

yml_write 'inherit' "${BASE}${SEPARATOR}${TMP}"
yml_write 'env.[].backup_level' "$BACKUP_LEVEL"
yml_write 'env.[].domain' "$DOMAIN"
yml_write 'backup.schedule' "${SCHEDULE_FULL}"
yml_write 'backup.tag.[]' "${DOMAIN}"
yml_write 'backup.tag.[]' "kvm"
yml_write 'backup.tag.[]' "${BACKUP_LEVEL}"
yml_write 'retention.tag.[]' "${DOMAIN}"
yml_write 'retention.tag.[]' "kvm"
yml_write 'retention.tag.[]' "${BACKUP_LEVEL}"

