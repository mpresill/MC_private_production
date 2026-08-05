#!/bin/bash

if [ -z "$1" ]
then
  echo "Usage: ./run.sh path/to/base/output/dir/ random_seed"
  exit 1
fi

if [[ $2 != +([0-9]) ]];
then
  echo "random_seed must be an integer value (it's used to set the unique random seed)"
  echo "Usage: ./run.sh path/to/base/output/dir/ random_seed"
  exit 1
fi

# for grid proxy: typically only needed for the condor jobs, not for local ones.
# Only override if the given path is actually readable here: under condor the
# starter already points X509_USER_PROXY at the copy it shipped into the sandbox,
# and the submit-side path (e.g. on AFS) may not be reachable on the worker node.
if [ -n "$3" ] && [ -r "$3" ]
then
  export X509_USER_PROXY=$3
fi

myOutputDir=$1
proc=$2

# Map the output directory onto an xrootd redirector + remote path.
# Note FNAL EOS is mounted as /eos/uscms/store/... at the LPC, but its xrootd
# namespace starts at /store/..., so the /eos/uscms prefix has to be stripped.
redirector=""
remoteDir=""
case "$myOutputDir" in
  /eos/uscms/*) redirector="root://cmseos.fnal.gov" ; remoteDir="${myOutputDir#/eos/uscms}" ;;
  /store/*)     redirector="root://cmseos.fnal.gov" ; remoteDir="$myOutputDir" ;;
  /eos/cms/*)   redirector="root://eoscms.cern.ch"  ; remoteDir="$myOutputDir" ;;
  /eos/*)       redirector="root://eosuser.cern.ch" ; remoteDir="$myOutputDir" ;;
esac

if [ -n "$redirector" ]; then
  dest=$redirector/$remoteDir/nanoaod_$proc.root
  # fail-fast if xrootd is available outside the container; it is re-tried inside
  # the container right before the copy, where the CMSSW environment guarantees it
  if command -v xrdfs >/dev/null 2>&1; then
    xrdfs $redirector mkdir -p $remoteDir || echo "WARNING: could not pre-create $redirector/$remoteDir (may already exist)"
  fi
else
  dest=$myOutputDir/nanoaod_$proc.root
  mkdir -p $myOutputDir
fi

baseDir=.
tar -xzf CMSSW_14_0_21_patch4.tar.gz
tar -xzf CMSSW_14_0_22.tar.gz
tar -xzf CMSSW_15_0_17.tar.gz
cmsswLHEGSDir=$baseDir/CMSSW_14_0_21_patch4/src
cmsswDRPremixDir=$baseDir/CMSSW_14_0_22/src
cmsswMiniNanoDir=$baseDir/CMSSW_15_0_17/src
cfgDir=.
nevents=${NEVENTS:-500}
nthreads=${NTHREADS:-1}
keeplog=${KEEPLOG:-0}
randomseed=$((1+$proc))

# The full chain is very verbose (~4 MB of stdout per 1000-event job). At campaign
# scale that does not fit in the AFS quota, so everything is captured into a log
# file in the job sandbox and only a short summary is printed. The full log is
# staged to EOS when the job fails, or always when KEEPLOG=1.
logfile=job_$proc.log

# `|| exit 1` after each cmsRun: without it a failed early step still burns hours
# running the remaining steps before dying at the stage-out
relinkcmd="echo -e \"\n[\$(date +%H:%M:%S)] Start relink the CMSSW\n\"; cd CMSSW_14_0_21_patch4/src; scramv1 b ProjectRename; cd -; cd CMSSW_14_0_22/src; scramv1 b ProjectRename; cd -; cd CMSSW_15_0_17/src; scramv1 b ProjectRename; cd -"
lhegscmd="echo -e \"\n[\$(date +%H:%M:%S)] Start gridpack to LHE GEN SIM (LHEGS)\n\"; cd $cmsswLHEGSDir; cmsenv; cd -; cmsRun -n $nthreads $cfgDir/lhe-gen-sim.py randomSeed=$randomseed nEvents=$nevents outputFile=sim.root || exit 1; rm -f sim_inLHE.root"
drpremix1cmd="echo -e \"\n[\$(date +%H:%M:%S)] Start SIM to PREMIXRAW (DRPremix 1/2)\n\"; cd $cmsswDRPremixDir; cmsenv; cd -; cmsRun -n $nthreads $cfgDir/gen-sim_to_premixraw.py outputFile=raw.root inputFiles=file:sim.root || exit 1; rm sim.root"
drpremix2cmd="echo -e \"\n[\$(date +%H:%M:%S)] Start PREMIXRAW to AOD (DRPremix 2/2)\n\"; cd $cmsswDRPremixDir; cmsenv; cd -; cmsRun -n $nthreads $cfgDir/premixraw_to_aod.py outputFile=aod.root inputFiles=file:raw.root || exit 1; rm raw.root"
minicmd="echo -e \"\n[\$(date +%H:%M:%S)] Start AOD to MINIAOD (MiniAODv6)\n\"; cd $cmsswMiniNanoDir; cmsenv; cd -; cmsRun -n $nthreads $cfgDir/aod_to_miniaod.py outputFile=miniaod.root inputFiles=file:aod.root || exit 1; rm aod.root"
nanocmd="echo -e \"\n[\$(date +%H:%M:%S)] Start MINIAOD to NANOAOD (NanoAODv15)\n\"; cd $cmsswMiniNanoDir; cmsenv; cd -; cmsRun -n $nthreads $cfgDir/miniaod_to_nanoaod.py outputFile=nanoaod.root inputFiles=file:miniaod.root || exit 1; rm miniaod.root"
if [ -n "$redirector" ]; then
  copycmd="echo -e \"\n[\$(date +%H:%M:%S)] Start stage-out to $dest\n\"; xrdfs $redirector mkdir -p $remoteDir; xrdcp -f nanoaod.root $dest || exit 1; rm -f nanoaod.root"
else
  copycmd="echo -e \"\n[\$(date +%H:%M:%S)] Start stage-out to $dest\n\"; mv nanoaod.root $dest || exit 1"
fi
cmd="cmssw-el8 -- \"source /cvmfs/cms.cern.ch/cmsset_default.sh; source /cvmfs/cms.cern.ch/common/crab-setup.sh; $relinkcmd; $lhegscmd; $drpremix1cmd; $drpremix2cmd; $minicmd; $nanocmd; $copycmd\""

start=$SECONDS
cmssw-el8 -- "source /cvmfs/cms.cern.ch/cmsset_default.sh; source /cvmfs/cms.cern.ch/common/crab-setup.sh; $relinkcmd; $lhegscmd; $drpremix1cmd; $drpremix2cmd; $minicmd; $nanocmd; $copycmd" > $logfile 2>&1
rc=$?
elapsed=$((SECONDS-start))

# confirm the file really landed: a silently missing output is the worst failure
# mode at campaign scale, so turn it into a job failure
outsize=""
if [ $rc -eq 0 ]; then
  if [ -n "$redirector" ]; then
    outsize=$(xrdfs $redirector stat $remoteDir/nanoaod_$proc.root 2>/dev/null | awk '/^Size:/{print $2}')
  else
    outsize=$(stat -c %s $dest 2>/dev/null)
  fi
  if [ -z "$outsize" ] || [ "$outsize" -eq 0 ] 2>/dev/null; then
    echo "ERROR: stage-out reported success but $dest is missing or empty"
    rc=65
  fi
fi

echo "================================ job summary ================================"
echo "workdir     : $(pwd)"
echo "host        : $(hostname)"
echo "process     : $proc  (random seed $randomseed)"
echo "events      : $nevents"
echo "threads     : $nthreads"
echo "destination : $dest"
echo "output size : ${outsize:-n/a} bytes"
echo "wall time   : $elapsed s"
echo "exit code   : $rc"
echo "--- step markers ---"
grep -E '^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] Start ' $logfile
echo "============================================================================="

# keep the full log for the reference sample, and always when something went wrong
if [ $rc -ne 0 ] || [ "$keeplog" = "1" ]; then
  gzip -c $logfile > $logfile.gz
  if [ -n "$redirector" ]; then
    xrdfs $redirector mkdir -p $remoteDir/logs
    xrdcp -f $logfile.gz $redirector/$remoteDir/logs/$logfile.gz \
      || echo "WARNING: could not stage $logfile.gz to $redirector/$remoteDir/logs/"
  else
    mkdir -p $myOutputDir/logs && cp $logfile.gz $myOutputDir/logs/
  fi
fi

if [ $rc -ne 0 ]; then
  echo "JOB FAILED (exit $rc). Command was:" >&2
  echo "$cmd" >&2
  echo "--- lines matching Exception/Fatal/Error ---" >&2
  grep -E 'Exception|FatalRootError|----- Begin Fatal|\*\*\* Break \*\*\*|command not found|No such file' $logfile | tail -40 >&2
  echo "--- last 300 lines of $logfile ---" >&2
  tail -300 $logfile >&2
fi

exit $rc
