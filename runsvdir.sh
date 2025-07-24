#!/usr/bin/env bash
exec 2>&1

if readlink -f . >/dev/null 2>&1
then
    readlink=readlink
else
    if greadlink -f . >/dev/null 2>&1
    then
        readlink=greadlink
    else
        echo "You must install greadlink to use this (brew install coreutils)" >&2
    fi
fi
# Set here to the full path to this script
me=${BASH_SOURCE[0]}
[ -L "$me" ] && me=$($readlink -f "$me")
here=$(cd "$(dirname "$me")" && pwd)
root=$(cd "$here/.." && pwd)

cd "$root" || {
    echo "Could not cd to $root" >&2
    exit 1
}
if [ -z "$HOSTNAME" ]
then
    echo "HOSTNAME not set, using $(hostname)" >&2
    HOSTNAME=$(hostname)
else
    echo "HOSTNAME is $HOSTNAME" >&2
fi
service_root="$root/service"
servicedir="$service_root/generic"
first_level_host="${HOSTNAME%-*}"
second_level_host="${first_level_host%-*}"
prefix="${SV_PREFIX}"

if [ -d "$service_root/$HOSTNAME" ]
then
    servicedir="$service_root/$HOSTNAME"
elif [ -d "$service_root/$first_level_host" ]
then
    servicedir="$service_root/$first_level_host"
elif [ -d "$service_root/$second_level_host" ]
then
    servicedir="$service_root/$second_level_host"
elif [ -d "$service_root/${prefix}${first_level_host}" ]
then
    servicedir="$service_root/${prefix}${first_level_host}"
elif [ -d "$service_root/${prefix}${second_level_host}" ]
then
    servicedir="$service_root/${prefix}${second_level_host}"
else
    echo "No service directory found for $HOSTNAME" >&2
    echo "Using $servicedir" >&2
fi

if [ "$(id -u)" != "0" ]
then
    ln -sf "$servicedir" /service
    chown rsvlog:adm /service/*/log/main
fi

echo "Starting runsvdir in $servicedir" >&2
exec runsvdir -P "$servicedir"
