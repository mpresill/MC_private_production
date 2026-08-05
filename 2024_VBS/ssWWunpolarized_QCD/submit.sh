#!/bin/bash

if [ -z "$1" ]
then
  echo "Usage: ./submit.sh path/to/base/output/dir [jdl file, default run.jdl] [key=value ...]"
  echo "  Output dir may be local, CERN EOS (/eos/user/..., /eos/cms/...) or"
  echo "  FNAL EOS (/eos/uscms/store/... or /store/...)."
  echo "  Any extra key=value arguments are passed straight to condor_submit, e.g."
  echo "  ./submit.sh /store/group/... run.jdl nevents=1000 njobs=5000 nthreads=2"
  exit 1
fi

# needed for the xrdfs checks below. Use the same proxy the jdl hands to the jobs,
# ignoring a X509_USER_PROXY that points at a file that isn't there (lxplus profiles
# often preset it to ~/.globus/x509up, which voms-proxy-init may never have written)
if [ ! -r "${X509_USER_PROXY:-}" ]; then
  export X509_USER_PROXY=/afs/cern.ch/user/m/mpresill/.proxy
fi

outdir=$1
shift
jdl=run.jdl
if [ -n "$1" ] && [[ "$1" != *=* ]]
then
  jdl=$1
  shift
fi
if [ ! -f "$jdl" ]
then
  echo "No such jdl file: $jdl"
  exit 1
fi

# Same path -> redirector mapping as run.sh (FNAL EOS xrootd namespace has no
# /eos/uscms prefix). Empty redirector means the path is a plain local one.
case "$outdir" in
  /eos/uscms/*) redirector="root://cmseos.fnal.gov" ; remoteDir="${outdir#/eos/uscms}" ;;
  /store/*)     redirector="root://cmseos.fnal.gov" ; remoteDir="$outdir" ;;
  /eos/cms/*)   redirector="root://eoscms.cern.ch"  ; remoteDir="$outdir" ;;
  /eos/*)       redirector="root://eosuser.cern.ch" ; remoteDir="$outdir" ;;
  *)            redirector=""                       ; remoteDir="$outdir" ;;
esac

# Refuse to submit into a directory that already holds output, so we don't
# overwrite anything by mistake. An existing but empty directory is fine.
if [ -n "$redirector" ]
then
  if ! xrdfs $redirector stat $remoteDir > /dev/null 2>&1
  then
    echo "Creating $redirector/$remoteDir"
    xrdfs $redirector mkdir -p $remoteDir || exit 1
  elif [ -n "$(xrdfs $redirector ls $remoteDir 2>/dev/null)" ]
  then
    echo "Directory $redirector/$remoteDir exists and is not empty! Please pick a new"
    echo "directory or delete the existing contents, so we don't overwrite any outputs"
    echo "by mistake"
    exit 1
  fi
elif [ -d "$outdir" ] && [ -n "$(ls -A "$outdir" 2>/dev/null)" ]
then
  echo "Directory $outdir exists and is not empty! Please pick a new directory or delete the"
  echo "existing contents, so we don't overwrite any outputs by mistake"
  exit 1
fi

condor_submit outdir=$outdir "$@" $jdl
