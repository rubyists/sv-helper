#!/usr/bin/env bash
exec 2>&1

if ! command -v realpath >/dev/null 2>&1
then
    echo "You must install realpath to use this" >&2
    exit 1
fi

me=${BASH_SOURCE[0]}
here=$(cd "$(dirname "$me")" && pwd)
real_here=$(realpath "$here")
root=$(cd "$real_here/.." && pwd)

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

if [ -z "$SVDIR" ]
then
    echo "SVDIR not set, finding the servicedir" >&2
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
    SVDIR="$servicedir"
else
    servicedir="$SVDIR"
fi

if [ "$(id -u)" -eq 0 ]
then
    ln -sf "$servicedir" /service
    SVDIR="/service"
else
    SVDIR="$servicedir"
fi

export SVDIR

echo "Starting runsvdir in $servicedir" >&2
exec runsvdir -P "$servicedir"
