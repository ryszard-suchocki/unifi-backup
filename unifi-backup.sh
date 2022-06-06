#!/bin/bash

VERSION="1.0.2"
APP_NAME="turbobackup"

# Realizacja scenariusza:
# przygotowanie do backup - pełny (full, zawsze commit do bazy/podstawy), różnicowy (diff, baza + jedna zależna. Pośrednie "incr" spłaszczone do "diff"(blockpull)), przyrostowa (od ostatniej pełnej,różnicowej lub poprzedniej typu "incr")
# dwa tryby kopii - archiwum (kompresja, dedup) i rsync (czysta kopia, gotowa do rozruchu). Zawsze zrzut konfiguracji VM (konfiguracja do incr,diff lub full - nie zwiera ostatniego incr)
# przewidzenie kolizji nazwowej dysku przy trybie rsync (vmdisk.qcow2 w /folder/A/ i /folder/B/ - dla VM to różne dyski, dla rsync do /folder/C/ nastąpi kolizja).
# --------- problematyczne zrzucenie konfiguracji docelowej. Po przekopiowaniu do jednego folderu, który nie jest docelowy, zrzut wydaje się bezcelowy (trzeba by zmodyfikować cały łańcuch aka "rebase")
#
# domena bez jakiejkowiek kopii
# domena z conajmniej jedną kopią / wykorzystany external snapshot
# domena w ruchu / obsługa virsh
# domena zatrzymana bez kopii/ obsługa przez qemu-img i virt-xml
# domena zatrzymana z kopią / obsługa przez qemu-img i virt-xml
#
# virsh - sprawdzić czy domena istnieje / jest zdefiniowana
# virsh - okreslic aktualnie wykorzystywane dyski (dziala dla offline i online)
# qemu-img - okreslic zaleznosci aka backing files
# utworzyć funkcje generyczną do snapshotu:
#  - dla offline dla każdego dysku oddzielnie (zapewnic, by VM sie nie uruchomiła)(image exchange / virt-xml)
#  - dla online virsh create-snapshot-as
#
# Utworzyc funkcje generyczna do commitu:
#  - flatten - roznicowa (diff)
#  - consolidation - pełna (full)
#  - kasowanie nieużywanych dysków w starym łańcuchu. Oczyszczenie folderów z plików nie wykorzystywanych w działającej VM.

QEMU_IMG="/usr/bin/qemu-img"
VIRSH="/usr/bin/virsh"
QEMU="/usr/bin/qemu-system-x86_64"
QEMU_IMG_SHARE_FLAG="--force-share"
DEBUG=0
VERBOSE=0
DUMP_STATE=0
QUIESCE=0
BACKUP_DIRECTORY=
SNAPSHOT_PREFIX="bimg"
DUMP_STATE_TIMEOUT=180 # 16GB RAM / 50MB/s = 16 384 / 50 = 328s
DUMP_STATE_DIRECTORY=
PRINT_FILES=0


_ret=0 # return variable


function print_usage() {
    [ -n "$1" ] && (echo "" ; print_v e "$1\n")
    
   cat <<EOU
   $APP_NAME version $VERSION - Ryszard Suchocki feat. Davide Guerri

   Usage:

   $0 [-a <action> -m <mode>] [-b <directory>] [-q|-s <directory>] [-h] [-d] [-v] [-V] [-p] <domain name>|all

   Options:
      -a <action>
      -m <method>       Specified action mode/method: backup:[full|diff|incr|enable|disable|showchain] sync:[inplace|full|diff] maintenance:[enter|save|drop]
      -b <directory>    Copy previous snapshot/base image to the specified <directory> # not yet implemented
      -q                Use quiescence (qemu agent must be installed in the domain)
      -s <directory>    Dump domain status in the specified directory
      -d                Debug
      -h                Print usage and exit
      -v                Verbose
      -V                Print version and exit
      -p                Print files to backup

   Version Requirements:
      bash     >= 4.3.0
      qemu_img >= 1.2.0
      qemu     >= 1.2.0
      virsh    >= 0.9.13

EOU
}

function print_v() {
    local level=$1
    
    case $level in
        v) # Verbose
            [ $VERBOSE -eq 1 ] && echo -e "[VVV] ${*:2}"
        ;;
        d) # Debug
            [ $DEBUG -eq 1 ] && echo -e "[DBG] ${*:2}"
        ;;
        e) # Error
            echo -e "[ERR] ${*:2}"
        ;;
        w) # Warning
            echo -e "[WAR] ${*:2}"
        ;;
        *) # Any other level
            echo -e "[INF] ${*:2}"
        ;;
    esac
}

# Mutual exclusion management: only one instance of this script can be running
# at one time.
function try_lock() {
    local domain_name=$1
    
    exec 29>"/var/lock/$domain_name.fi-backup.lock"
    
    flock -n 29
    
    if [ $? -ne 0 ]; then
        return 1
    else
        return 0
    fi
}

function unlock() {
    local domain_name=$1
    
    rm "/var/lock/$domain_name.fi-backup.lock"
    exec 29>&-
}

function is_domain_running() {
    local domain_name=$1
    local dom_state=
    dom_state=$($VIRSH domstate "$domain_name" 2>&1)
    if [ "$dom_state" != "running" ]; then
        # print_v w "Warning: Active block commit requires '$domain_name' to be running"
        return 1
    else
        return 0
    fi
}

function is_domain_defined() {
    tmp=$(virsh dominfo "$1" &>/dev/null)
    if [ $? -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

function dump_config() {
    local domain_name=$1
    local print_path=$2
    local dump_path="$(dirname $(virsh domblklist ${domain_name} --details | grep disk | head -n1 | awk '{print $4}'))"
    local command="virsh dumpxml ${domain_name}"
    print_v d $command
    local command_output1=$($command > ${dump_path}/${domain_name}.xml)
    local command_output2=$($command --inactive > ${dump_path}/${domain_name}-inactive.xml)
    local command_output3=$($command --migratable > ${dump_path}/${domain_name}-migratable.xml)
    
    print_v d $command_output1
    print_v d $command_output2
    print_v d $command_output3
    
    if [ ! -z $print_path ]; then
        echo "${dump_path}/${domain_name}.xml"
    fi
}


function dump_state() {
    local domain_name=$1
    local timestamp=$2
    local _ret=
    local _timeout=
    local _dump_state_filename="$DUMP_STATE_DIRECTORY/$domain_name.statefile-$timestamp.gz"
    local output=
    
    output=$($VIRSH qemu-monitor-command "$domain_name" '{"execute": "migrate", "arguments": {"uri": "exec:gzip -c > ' "'$_dump_state_filename'" '"}}' 2>&1)
    if [ $? -ne 0 ]; then
        print_v e "Failed to dump domain state: '$output'"
        return 1
    fi
    
    _timeout=5
    print_v d "Waiting for dump file '$_dump_state_filename' to be created"
    while [ ! -f "$_dump_state_filename" ]; do
        _timeout=$((_timeout - 1))
        if [ "$_timeout" -eq 0 ]; then
            print_v e "Timeout while waiting for dump file to be created"
            return 4
        fi
        sleep 1
        print_v d "Still waiting for dump file '$_dump_state_filename' to be created ($_timeout)"
    done
    print_v d "Dump file '$_dump_state_filename' created"
    
    if [ ! -f "$_dump_state_filename" ]; then
        print_v e "Dump file not created ('$_dump_state_filename'), something went wrong! ('$output' ?)"
        return 1
    fi
    
    _timeout="$DUMP_STATE_TIMEOUT"
    print_v d "Waiting for '$domain_name' to be paused"
    while true; do
        output=$(virsh domstate "$domain_name")
        if [ $? -ne 0 ]; then
            print_v e "Failed to check domain state"
            return 2
        fi
        if [ "$output" == "paused" ]; then
            print_v d "Domain paused!"
            break
        fi
        if [ "$_timeout" -eq 0 ]; then
            print_v e "Timeout while waiting for VM to pause: '$output'"
            return 3
        fi
        print_v d "Still waiting for '$domain_name' to be paused ($_timeout)"
        sleep 1
        _timeout=$((_timeout - 1))
    done
    
    return 0
}

function get_block_devices() {
    local domain_name=$1
    local -n return_var=$2
    local _ret=
    
    return_var=()
    
    while IFS= read -r file; do
        return_var+=("$file")
        done < <($VIRSH -q -r domblklist "$domain_name" --details|awk \
    '"disk"==$2 {$1=$2=$3=""; print $0}'|sed 's/^[ \t]*//')
    
    return 0
}

function get_backing_file() {
    local file_name=$1
    local -n _return_var=$2
    local _ret=
    local _backing_file=
    local version=
    
    #version=$(qemu_version)
    _backing_file=$($QEMU_IMG info $QEMU_IMG_SHARE_FLAG "$file_name" | \
    awk '/^backing file: / {$1=$2=""; print $0}'|sed 's/^[ \t]*//')
    _ret=$?
    if [[ $_ret == 1 ]]; then
        print_v e "Error in getting backing file: Check if running with sufficient permissions (sudo, apparmor status, etc)"
    fi
    
    _return_var="$_backing_file"
    
    return $_ret
}

function get_snapshot_chain() {
    local endmost_child=$1
    local -n return_var=$2
    local _parent_backing_file=
    local _backing_file=
    local i=0
    local _ret=
    
    return_var[$i]="$endmost_child"
    
    _ret=1
    
    get_backing_file "$endmost_child" _parent_backing_file
    if [ $? -eq 0 ]; then
        while [ -e "$_parent_backing_file" ]; do
            ((i++))
            return_var[$i]="$_parent_backing_file"
            #get next backing file if it exists
            _backing_file="$_parent_backing_file"
            get_backing_file "$_backing_file" _parent_backing_file
            #print_v d "Next file in backing file chain: '$_parent_backing_file'"
            _ret=0
        done
    fi
    
    return $_ret
}

function commit_offline_domain(){
    local domain_name=$1
    local base_image=$2
    local snap_image=$3
    
    local command="qemu-img commit $snap_image"
    print_v d $command
    command_output=$(${command} 2>&1)
    if [ $? -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

function rebase_offline_domain(){
    local domain_name=$1
    local base_image=$2
    local snap_image=$3
    
    command="qemu-img rebase -p -b ${base_image} ${snap_image}"
    print_v d $command
    command_output=$(${command} 2>&1)
    if [ $? -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

function snapshot_domain() {
    local domain_name=$1
    local _ret=0
    local backing_file=
    local block_device=
    local block_devices=
    local extra_args=
    local command_output=
    local new_backing_file=
    local parent_backing_file=
    local timestamp=
    local resume_vm=0
    
    timestamp=$(date "+%Y%m%d-%H%M%S")
    
    print_v d "Snapshot for domain '$domain_name' requested"
    print_v d "Using timestamp '$timestamp'"
    if ! is_domain_running "${domain_name}"; then
        print_v d "Domain ${domain_name} is not running"
        get_block_devices "$domain_name" block_devices
        for ((i=0; i<"${#block_devices[@]}";i++)); do
            local filename=$(basename -- "${block_devices[$i]}")
            local extension="${filename##*.}"
            local filename="${filename%.*}"
            local base_image="${block_devices[$i]}"
            print_v d "Base image: $base_image"
            local base_path=$(dirname $base_image)
            print_v d "Base image path: $base_path"
            local snap_image="${base_path}/${filename}.${SNAPSHOT_PREFIX}-${timestamp}"
            print_v d "New overlay image: $snap_image"
            local target_dev=$(virsh domblklist "$domain_name" --details | grep disk | grep $base_image | awk '{print $3}')
            local command="qemu-img create -f qcow2 -o backing_fmt=qcow2,backing_file=$base_image $snap_image"
            print_v d $command
            command_output=$(${command} 2>&1)
            _ret=$?
            if [ $_ret -eq 0 ]; then
                print_v d "${command_output}"
                command="virt-xml $domain_name --edit target=$target_dev --disk driver_type=qcow2,path=$snap_image"
                print_v d $command
                command_output=$($command 2>&1)
                _ret=$?
                if [ $_ret -eq 0 ]; then
                    print_v d "Snapshot image '$snap_image' mounted as target device '$target_dev'"
                    print_v d "${command_output}"
                else
                    print_v e "Snapshot image '$snap_image' couldn't be mounted as target device '$target_dev'"
                    print_v e "${command_output}"
                fi
            else
                print_v e "Unable snapshot '$base_image' disk."
                print_v e "${command_output}"
            fi
        done
        return $_ret
    else
        print_v d "Domain ${domain_name} is running"
        if [ "$DUMP_STATE" -eq 1 ]; then  # Dump VM state
            print_v v "Dumping domain state"
            dump_state "$domain_name" "$timestamp"
            _ret=$?
            if [ $_ret -ne 0 ]; then
                print_v e \
                "Domain state dump failed!"
                return 1
            else
                resume_vm=1  # Should something go wrong, resume the domain
                trap 'virsh resume "$domain_name" >/dev/null 2>&1' SIGINT SIGTERM
                if [ "$resume_vm" -eq 1 ]; then
                    print_v d "Resuming domain"
                    virsh resume "$domain_name" >/dev/null 2>&1
                    if [ $? -ne 0 ]; then
                        print_v e "Problem resuming domain '$domain_name'"
                        return 1
                    else
                        print_v v "Domain resumed"
                        trap "" SIGINT SIGTERM
                    fi
                fi
            fi
        fi
        
        # Create an external snapshot for each block device
        print_v d "Snapshotting block devices for '$domain_name' using suffix '$SNAPSHOT_PREFIX-$timestamp'"
        
        if [ $QUIESCE -eq 1 ]; then
            print_v d "Quiesce requested"
            extra_args="--quiesce"
        fi
        
        print_v v "$VIRSH -q snapshot-create-as $domain_name" \
        "$SNAPSHOT_PREFIX-$timestamp --no-metadata --disk-only --atomic "\
        "$extra_args"
        
        command_output=$($VIRSH -q snapshot-create-as "$domain_name" \
            "$SNAPSHOT_PREFIX-$timestamp" --no-metadata --disk-only --atomic \
        $extra_args 2>&1)
        _ret=$?
        if [ $_ret -eq 0 ]; then
            print_v v "Snapshot for block devices of '$domain_name' successful"
        else
            print_v e \
            "Snapshot for '$domain_name' failed! Exit code: $_ret\n'$command_output'"
            if [[ $command_output =~ "Permission denied" ]]; then
                print_v e "Check apparmor status or check if running with sufficient permissions"
            fi
        fi
        
        return $_ret
    fi
}

function print_backing_chain(){
    local domain_name=$1
    get_block_devices "$domain_name" block_devices
    for ((i=0; i<"${#block_devices[@]}";i++)); do
        local target_dev=$(virsh domblklist "$domain_name" --details | grep disk | grep ${block_devices[$i]} | awk '{print $3}')
        print_v d "Backing chain for block device: ${target_dev}"
        get_snapshot_chain "${block_devices[$i]}" snapshot_chain_flat
        for ((j=0 ; j<"${#snapshot_chain_flat[@]}";j++)); do
            snapshot_chain[$i,$j]="${snapshot_chain_flat[$j]}"
            print_v d "$j)"
            echo "${snapshot_chain[$i,$j]}"
        done
    done
    return 0
}

function purge_backing_files(){
    local -n old_backing_files=$1
    local -n new_backing_files=$2
    local files_to_remove=(`echo ${old_backing_files[@]} ${new_backing_files[@]} | tr ' ' '\n' | sort | uniq -u`)
    #print_v d "Files to remove: ${files_to_remove}"
    print_v d "Files to remove: ${#files_to_remove[@]}"
    for ((k=0 ; k<"${#files_to_remove[@]}";k++)); do
        local command="rm  ${files_to_remove[$k]}"
        print_v d $command
        local command_output=$($command)
        print_v d $command_output
    done
}

function flatten_consolidate(){
    
    local domain_name=$1
    local request_action=$2
    
    local block_devices=''
    local block_devices_modif=''
    local backin_file=''
    local snapshot_chain_flat=''
    local snapshot_chain_flat_modif=''
    local block_devices_count=0
    local _ret=0
    declare -A snapshot_chain
    
    get_block_devices "$domain_name" block_devices
    
    for ((i=0; i<"${#block_devices[@]}";i++)); do
        get_snapshot_chain "${block_devices[$i]}" snapshot_chain_flat
        for ((j=0 ; j<"${#snapshot_chain_flat[@]}";j++)); do
            snapshot_chain[$i,$j]="${snapshot_chain_flat[$j]}"
            print_v d "${snapshot_chain[$i,$j]}"
        done
        if [ ! -z $request_action ] && [ $request_action == "flatten" ]; then
            if [ "${#snapshot_chain_flat[@]}" -gt 2 ]; then
                print_v d ""
                print_v d "Flattening possible - ${block_devices[$i]} to ${snapshot_chain_flat[(${#snapshot_chain_flat[@]}-2)]}"
                
                if is_domain_running "${domain_name}" && [ $? == 0 ]; then
                    command="virsh blockpull --domain ${domain_name} --path ${block_devices[$i]} --base ${snapshot_chain_flat[(${#snapshot_chain_flat[@]}-1)]} --verbose --wait"
                    print_v d $command
                    command_output=$($command 2>&1)
                    _ret=$?
                    print_v d $command_output
                else
                    command="rebase_offline_domain $domain_name ${snapshot_chain_flat[(${#snapshot_chain_flat[@]}-1)]} ${snapshot_chain_flat[0]}"
                    print_v d $command
                    command_output=$($command 2>&1)
                    _ret=$?
                    print_v d $command_output
                fi
                if [ $_ret -eq 0 ]; then
                    get_block_devices "$domain_name" block_devices_modif
                    get_snapshot_chain "${block_devices_modif[$i]}" snapshot_chain_flat_modif
                    purge_backing_files snapshot_chain_flat snapshot_chain_flat_modif
                fi
                print_v d ""
            fi
        fi
        
        if [ ! -z $request_action ] && [ $request_action == "consolidate" ]; then
            if [ "${#snapshot_chain_flat[@]}" -gt 1 ]; then
                print_v d ""
                print_v d "Consolidation possible. ${block_devices[$i]} to ${snapshot_chain_flat[(${#snapshot_chain_flat[@]}-1)]}"
                if is_domain_running "${domain_name}" && [ $? == 0 ]; then
                    command="virsh blockcommit --domain ${domain_name} --path ${block_devices[$i]} --verbose --pivot"
                    print_v d $command
                    command_output=$($command 2>&1)
                    _ret=$?
                    print_v d $command_output
                else
                    local base_image="${snapshot_chain_flat[(${#snapshot_chain_flat[@]}-1)]}"
                    print_v d "Base image: $base_image"
                    local snap_image="${snapshot_chain_flat[0]}"
                    print_v d "Overlay image: $snap_image"
                    local target_dev=$(virsh domblklist "$domain_name" --details | grep disk | grep ${snap_image} | awk '{print $3}')
                    command="commit_offline_domain $domain_name ${base_image} ${snap_image}"
                    print_v d $command
                    command_output=$($command 2>&1)
                    if [ $? -eq 0 ]; then
                        print_v d "${command_output}"
                        command="virt-xml $domain_name --edit target=$target_dev --disk driver_type=qcow2,path=$base_image --define"
                        print_v d $command
                        command_output=$($command 2>&1)
                        if [ $? -eq 0 ]; then
                            _ret=0
                            print_v d "Base image '$base_image' mounted as target device '$target_dev'"
                            print_v d "${command_output}"
                        else
                            _ret=1
                            print_v e "Base image '$base_image' couldn't be mounted as target device '$target_dev'"
                            print_v e "${command_output}"
                            return 1
                        fi
                    else
                        _ret=1
                    fi
                fi
                if [ $_ret -eq 0 ]; then
                    get_block_devices "$domain_name" block_devices_modif
                    get_snapshot_chain "${block_devices_modif[$i]}" snapshot_chain_flat_modif
                    purge_backing_files snapshot_chain_flat snapshot_chain_flat_modif
                fi
                print_v d ""
            fi
        fi
        block_devices_count=$(($i+1))
        unset snapshot_chain_flat
        if [ $_ret -ne 0 ]; then
            return 1
        fi
    done
    return 0
}

TEMP=$(getopt -n "$APP_NAME" -o a:m:b:s:qhdvVp --long action:,mode:,backup_dir:,dump_state_dir:,quiesce,help,debug,version,verbose,print-files -- "$@")
if [ $? != 0 ] ; then echo "Failed parsing options." >&2 ; exit 1 ; fi

eval set -- "$TEMP"
while true; do
    case "$1" in
        -b|--backup_dir)
            BACKUP_DIRECTORY=$2
            if [ ! -d "$BACKUP_DIRECTORY" ]; then
                print_v e "Backup directory '$BACKUP_DIRECTORY' doesn't exist!"
                exit 1
            fi
            shift; shift
        ;;
        -a|--action)
            declare -a ACTIONLIST=()
            ACTIONLIST=("backup" "sync" "maintenance")
            ACTION=$2
            if ! [[ " ${ACTIONLIST[*]} " =~ " ${ACTION} " ]]; then
                print_usage "-a requires specifying 'backup', 'sync' or 'maintenance' "
                exit 1
            fi
            declare -a MODELIST=()
            if [ "$ACTION" == "backup" ]; then
                MODELIST=("full" "incr" "diff" "enable" "disable" "showchain")
            elif [ "$ACTION" == "sync" ]; then
                MODELIST=("inplace" "full" "incr")
            elif [ "$ACTION" == "maintenance" ]; then
                MODELIST=("enter" "save" "drop")
            else
                print_usage "-a requires specifying 'backup', 'sync' or 'maintenance' "
            fi
            shift;shift
        ;;
        -m|--mode)
            MODE=$2
            if ! [[ " ${MODELIST[*]} " =~ " ${MODE} " ]]; then
                print_usage "-m requires specifying proper mode/method."
                exit 1
            fi
            shift;shift
        ;;
        -q|--quiesce)
            QUIESCE=1
            shift
        ;;
        -p|--print-files)
            PRINT_FILES=1
            shift
        ;;
        -s|--dump_state_dir)
            DUMP_STATE=1
            DUMP_STATE_DIRECTORY=$2
            if [ ! -d "$DUMP_STATE_DIRECTORY" ]; then
                print_v e \
                "Dump state directory '$DUMP_STATE_DIRECTORY' doesn't exist!"
                exit 1
            fi
            shift;shift
        ;;
        -d|--debug)
            DEBUG=1
            VERBOSE=1
            shift
        ;;
        -h|--help)
            print_usage
            exit 1
            shift
        ;;
        -v|--verbose)
            VERBOSE=1
            shift
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

DOMAIN_NAME="$1"

if ! is_domain_defined $DOMAIN_NAME; then
    print_v e "Domain $DOMAIN_NAME not defined!"
    exit 1
fi

try_lock "$DOMAIN_NAME"
_ret=$?
if [ $_ret -ne 0 ]; then
    print_v e "Another instance of $0 is already running on '$DOMAIN_NAME'! Skipping backup of '$DOMAIN_NAME'"
fi

if [ "$ACTION" == "backup" ]; then
    case $MODE in
        "full")
            flatten_consolidate "${DOMAIN_NAME}" "consolidate"
            _ret=$?
            if [ $_ret -eq 0 ]; then
                if [ $PRINT_FILES -eq 1 ];then
                    print_backing_chain "${DOMAIN_NAME}"
                    dump_config "${DOMAIN_NAME}" "true"
                else
                    dump_config "${DOMAIN_NAME}"
                fi
                SNAPSHOT_PREFIX="incr"
                snapshot_domain "${DOMAIN_NAME}"
                _ret=$?
            else
                _ret=1
            fi
        ;;
        "diff")
            SNAPSHOT_PREFIX="diff"
            snapshot_domain "${DOMAIN_NAME}"
            _ret=$?
            if [ $_ret -eq 0 ]; then
                flatten_consolidate "${DOMAIN_NAME}" "flatten"
                _ret=$?
                if [ $_ret -eq 0 ]; then
                    if [ $PRINT_FILES -eq 1 ];then
                        print_backing_chain "${DOMAIN_NAME}"
                        dump_config "${DOMAIN_NAME}" "true"
                    else
                        dump_config "${DOMAIN_NAME}"
                    fi
                    SNAPSHOT_PREFIX="incr"
                    snapshot_domain "${DOMAIN_NAME}"
                    _ret=$?
                else
                    _ret=1
                fi
            else
                _ret=1
            fi
        ;;
        "incr")
            if [ $PRINT_FILES -eq 1 ];then
                print_backing_chain "${DOMAIN_NAME}"
                dump_config "${DOMAIN_NAME}" "true"
            else
                dump_config "${DOMAIN_NAME}"
            fi
            SNAPSHOT_PREFIX="incr"
            snapshot_domain "${DOMAIN_NAME}"
            _ret=$?
        ;;
        "enable")
            if [ $PRINT_FILES -eq 1 ];then
                print_backing_chain "${DOMAIN_NAME}"
                dump_config "${DOMAIN_NAME}" "true"
            else
                dump_config "${DOMAIN_NAME}"
            fi
            SNAPSHOT_PREFIX="incr"
            snapshot_domain "${DOMAIN_NAME}"
            _ret=$?
            
        ;;
        "disable")
            print_v w " * * * This option will deactivate incremental backup * * * "
            print_v w "All changes waiting for commit will be flushed NOW to original disk"
            print_v w "Press [CTRL] + [C] to cancel action..."
            sleep 5
            flatten_consolidate "${DOMAIN_NAME}" "consolidate"
            _ret=$?
            if [ $PRINT_FILES -eq 1 ];then
                print_backing_chain "${DOMAIN_NAME}"
                dump_config "${DOMAIN_NAME}" "true"
            else
                dump_config "${DOMAIN_NAME}"
            fi
        ;;
        "showchain")
            print_backing_chain "${DOMAIN_NAME}"
            _ret=$?
        ;;
    esac
fi
if [ "$ACTION" == "sync" ]; then
    echo "Syncing"
    case $MODE in
        "inplace")
        ;;
        "full")
        ;;
        "incr")
        ;;
    esac
fi
if [ "$ACTION" == "maintenance" ]; then
    #echo "Maintenance"
    case $MODE in
        "enter")
            SNAPSHOT_PREFIX="maintenance"
            snapshot_domain "${DOMAIN_NAME}"
            _ret=$?
        ;;
        "save")
            print_v w " * * * This option will save maintenance result * * * "
            print_v w "All changes waiting for commit will be flushed NOW to original disk (base)"
            print_v w "Whole BACKUP CHAIN will be CONSOLIDATED to the one disk (base)"
            print_v w "Press [CTRL] + [C] to cancel action..."
            sleep 5
            flatten_consolidate "${DOMAIN_NAME}" "consolidate"
            _ret=$?
        ;;
        "drop")
        ;;
    esac
fi

unlock $DOMAIN_NAME
exit $_ret