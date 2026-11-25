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
# The job seed drives every random engine of the chain (gridpack, Pythia, Geant4,
# vertex, pileup mixing, digitisation, reco) and the job's block of lumi/event
# numbers, see the end of lhe-gen-sim.py / gen-sim_to_premixraw.py / premixraw_to_aod.py.
# SEEDOFFSET keeps this production's seeds apart from any other production made from
# the same gridpacks: two productions with the same seeds produce the same events, so
# whoever else runs these samples must use a different offset (e.g. 0 or 200000).
seedoffset=${SEEDOFFSET:-100000}
randomseed=$((1+$proc+$seedoffset))

# The gridpack lives on FNAL EOS (root:// path in lhe-gen-sim.py), so every job,
# on lxplus condor or CRAB, reads the same copy: it is downloaded here and handed to
# lhe-gen-sim.py as a local file. A GRIDPACK set by the caller (crab_job.sh) wins.
gridpackurl=$(sed -n "s|.*args = cms.vstring('\(root://[^']*\)').*|\1|p" $cfgDir/lhe-gen-sim.py)
if [ -z "${GRIDPACK:-}" ] && [ -n "$gridpackurl" ]; then
  for attempt in 1 2 3; do
    xrdcp -f --nopbar "$gridpackurl" gridpack.tar.xz && break
    echo "WARNING: gridpack download attempt $attempt failed"
    rm -f gridpack.tar.xz
    sleep 60
  done
  if [ ! -s gridpack.tar.xz ]; then
    echo "ERROR: could not download the gridpack $gridpackurl"
    exit 66
  fi
  GRIDPACK=$PWD/gridpack.tar.xz
fi

# The full chain is very verbose (~4 MB of stdout per 1000-event job). At campaign
# scale that does not fit in the AFS quota, so everything is captured into a log
# file in the job sandbox and only a short summary is printed. The full log is
# staged to EOS when the job fails, or always when KEEPLOG=1.
logfile=job_$proc.log

# `|| exit 1` after each cmsRun: without it a failed early step still burns hours
# running the remaining steps before dying at the stage-out
relinkcmd="echo -e \"\n[\$(date +%H:%M:%S)] Start relink the CMSSW\n\"; cd CMSSW_14_0_21_patch4/src; scramv1 b ProjectRename; cd -; cd CMSSW_14_0_22/src; scramv1 b ProjectRename; cd -; cd CMSSW_15_0_17/src; scramv1 b ProjectRename; cd -"
lhegscmd="echo -e \"\n[\$(date +%H:%M:%S)] Start gridpack to LHE GEN SIM (LHEGS)\n\"; cd $cmsswLHEGSDir; cmsenv; cd -; cmsRun -n $nthreads $cfgDir/lhe-gen-sim.py randomSeed=$randomseed nEvents=$nevents ${GRIDPACK:+gridpack=$GRIDPACK} outputFile=sim.root || exit 1; rm -f sim_inLHE.root"
drpremix1cmd="echo -e \"\n[\$(date +%H:%M:%S)] Start SIM to PREMIXRAW (DRPremix 1/2)\n\"; cd $cmsswDRPremixDir; cmsenv; cd -; cmsRun -n $nthreads $cfgDir/gen-sim_to_premixraw.py randomSeed=$randomseed outputFile=raw.root inputFiles=file:sim.root || exit 1; rm sim.root"
drpremix2cmd="echo -e \"\n[\$(date +%H:%M:%S)] Start PREMIXRAW to AOD (DRPremix 2/2)\n\"; cd $cmsswDRPremixDir; cmsenv; cd -; cmsRun -n $nthreads $cfgDir/premixraw_to_aod.py randomSeed=$randomseed outputFile=aod.root inputFiles=file:raw.root || exit 1; rm raw.root"
minicmd="echo -e \"\n[\$(date +%H:%M:%S)] Start AOD to MINIAOD (MiniAODv6)\n\"; cd $cmsswMiniNanoDir; cmsenv; cd -; cmsRun -n $nthreads $cfgDir/aod_to_miniaod.py outputFile=miniaod.root inputFiles=file:aod.root || exit 1; rm aod.root"
nanocmd="echo -e \"\n[\$(date +%H:%M:%S)] Start MINIAOD to NANOAOD (NanoAODv15)\n\"; cd $cmsswMiniNanoDir; cmsenv; cd -; cmsRun -n $nthreads $cfgDir/miniaod_to_nanoaod.py outputFile=nanoaod.root inputFiles=file:miniaod.root || exit 1; rm miniaod.root"
if [ -n "$redirector" ]; then
  copycmd="echo -e \"\n[\$(date +%H:%M:%S)] Start stage-out to $dest\n\"; xrdfs $redirector mkdir -p $remoteDir; xrdcp -f nanoaod.root $dest || exit 1; rm -f nanoaod.root"
else
  copycmd="echo -e \"\n[\$(date +%H:%M:%S)] Start stage-out to $dest\n\"; mv nanoaod.root $dest || exit 1"
fi
chain="source /cvmfs/cms.cern.ch/cmsset_default.sh; source /cvmfs/cms.cern.ch/common/crab-setup.sh; $relinkcmd; $lhegscmd; $drpremix1cmd; $drpremix2cmd; $minicmd; $nanocmd; $copycmd"
# The releases are el8 builds. On an el9 host (lxplus, CERN condor) the chain runs in
# an el8 container; on an el8 host (e.g. a CRAB job submitted from an el8 release)
# it runs directly, so no container is nested inside the grid job's own container.
if grep -q '^VERSION_ID="8' /etc/os-release 2>/dev/null; then
  cmd="bash -c \"$chain\""
  runner=(bash -c)
else
  cmd="cmssw-el8 -- \"$chain\""
  runner=(cmssw-el8 --)
fi

start=$SECONDS
"${runner[@]}" "$chain" > $logfile 2>&1
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
echo "process     : $proc  (random seed $randomseed = 1 + process + offset $seedoffset)"
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
