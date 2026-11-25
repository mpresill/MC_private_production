#!/bin/bash
# CRAB scriptExe: runs one job of the 2024_VBS chain (run.sh) on a grid node.
# CRAB calls it as: crab_job.sh <CRAB job number, 1-based> KEY=VALUE ...
# with the KEY=VALUE pairs from JobType.scriptArgs (see crab_cfg.py).

jobnum=$1
shift
for kv in "$@"; do
  export "$kv"
done

# The job index fixes the random seed and the event-ID block of the job (run.sh),
# so every task of a sample must cover its own range of indices: JOBOFFSET is the
# index of the task's first job.
proc=$((JOBOFFSET + jobnum - 1))
echo "CRAB job $jobnum -> job index $proc (JOBOFFSET $JOBOFFSET, SEEDOFFSET $SEEDOFFSET)"

# The gridpacks are not readable from the grid where they were made (CERN EOS user
# area), so each job fetches its sample's copy over xrootd.
for attempt in 1 2 3; do
  xrdcp -f --nopbar "$GRIDPACK_URL" gridpack.tar.xz && break
  echo "WARNING: gridpack download attempt $attempt failed"
  rm -f gridpack.tar.xz
  sleep 60
done
if [ ! -s gridpack.tar.xz ]; then
  echo "ERROR: could not download $GRIDPACK_URL"
  exit 66
fi

# run.sh gets a clean environment, as under condor on lxplus: the CMSSW environment
# CRAB set up for this script belongs to the submission release, not to the chain.
env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/cvmfs/cms.cern.ch/common \
  TMPDIR="${TMPDIR:-/tmp}" X509_USER_PROXY="$X509_USER_PROXY" X509_CERT_DIR="$X509_CERT_DIR" \
  NEVENTS="$NEVENTS" NTHREADS="$NTHREADS" SEEDOFFSET="$SEEDOFFSET" KEEPLOG=0 \
  GRIDPACK="$PWD/gridpack.tar.xz" \
  ./run.sh "$PWD/out" "$proc"
rc=$?
rm -f gridpack.tar.xz
if [ $rc -ne 0 ]; then
  exit $rc
fi

# CRAB stages out a fixed name and appends _<job number> itself
mv "out/nanoaod_$proc.root" nanoaod.root || exit 65

# CRAB needs a framework job report; the dummy PSet makes one in a second
cmsRun -j FrameworkJobReport.xml PSet.py
