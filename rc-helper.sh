#!/bin/bash

# {{{ Comments/Usage
: <<COMMENTSTRING
This is the beginning of a helper to enable/disable daemons and modules 
of Arch Linux /etc/rc.conf

This will also export some handy utilities like print_array, print_arrays, 
export_array, and export_arrays which art the partsbeing worked on now.  

Current usage:
  symlink this as print_arrays and/or export_arrays

  ./print_arrays -s /etc/rc.conf MODULES DAEMONS

From here need to make the awk modify those files or hand that off to sed.
After that break the _arrays functions down to pieces that can be run for a
a single array and make the _arrays functions simple loop wrappers
COMMENTSTRING
# }}}

# {{{ Debug printing
function debug {
  msg=$@
  if [ "x$DEBUG" != "x" ];then
    echo $msg >&2
  fi
}
# }}}

# {{{ Break apart some arrays
function export_arrays {
  debug "Exporting array"
  if [ "x$sourcefile" != "x" ];then
    debug sourcing $sourcefile 
    source $sourcefile
  fi
  debug $@
  for varname in $@;do
    echo -n -e "$varname${separator}"
    eval "_array=(\${"${varname}"[@]})"
    for _val in "${_array[@]}";do 
      echo -n -e "${_val}${separator}"
    done
    echo -n -e "$separator"
  done|awk -v sep="${separator}${separator}" '{sub(sep"$","",$0);print}'
}
# }}}

# {{{ print_arrays
function print_arrays {
  export_arrays $@|awk -F"${separator}" -v rs="${separator}${separator}" '
    BEGIN{RS=rs}
    {
      name=$1
      for(i=2;i<=NF;i++)vals[name,i]=$(i)
      vars[name]=""
    }
    END{
      for(idx in vars) {
        n=idx
        printf n": "
        for(oidx in vals) {
          if(oidx ~ n) printf vals[oidx]" "
        }
        print ""
      }
    }'
}
# }}}

# {{{ Main program/command parsing

cmd=$(basename $0) # set $cmd to the called program

# {{{ Option parsing for array stuff
function array_optparse {
  while getopts s:t: options $@;do
    debug "Getting opts"
    case $options in
      t) separator=$OPTARG ;;
      s) sourcefile=$OPTARG ;;
      *) echo "Invalid Option! Usage: $0 [-s <File To Source for ENV>] [-t <Field Separator>] ARG1 .. ARGN"
         echo "Both -s and -t are optional, but they must have arguments, default field separator is null (\\0)"
         exit 2;;
    esac
  done
  shift $((OPTIND-1))
  separator=${separator:-"\0"}
  _optargs=$@
}
# }}}

case $cmd in
  export_array) array_optparse $@;export_array $_optparse;;
  print_array) array_optparse $@;print_array $_optparse;;
  export_arrays) array_optparse $@;export_arrays $_optargs;;
  print_arrays) array_optparse $@;print_arrays $_optargs;;
  *) echo "Invalid command '$cmd'!"
     echo "Valid Commands: export_array, print_array, export_arrays, print_arrays"
     echo "Perhaps you need a symlink?"
     exit 127;;
esac
# }}}
# vi: ts=2:sw=2:foldmethod=marker
