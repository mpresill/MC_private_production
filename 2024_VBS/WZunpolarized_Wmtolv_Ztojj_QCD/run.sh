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

# for grid proxy: typically only needed for the condor jobs, not for local ones
if [ -n "$3" ]
then
  export X509_USER_PROXY=$3
fi

myOutputDir=$1
if [[ "$myOutputDir" == "/eos/"* ]]; then
  xrdfs root://eosuser.cern.ch mkdir -p $myOutputDir
else
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
randomseed=$((1+$2))
relinkcmd="echo -e \"\nStart relink the CMSSW\n\"; cd CMSSW_14_0_21_patch4/src; scramv1 b ProjectRename; cd -; cd CMSSW_14_0_22/src; scramv1 b ProjectRename; cd -; cd CMSSW_15_0_17/src; scramv1 b ProjectRename; cd -"
lhegscmd="echo -e \"\nStart gridpack to LHE GEN SIM (LHEGS)\n\"; cd $cmsswLHEGSDir; cmsenv; cd -; cmsRun $cfgDir/lhe-gen-sim.py randomSeed=$randomseed nEvents=$nevents outputFile=sim.root; rm -f sim_inLHE.root"
drpremix1cmd="echo -e \"\nStart SIM to PREMIXRAW (DRPremix 1/2)\n\"; cd $cmsswDRPremixDir; cmsenv; cd -; cmsRun $cfgDir/gen-sim_to_premixraw.py outputFile=raw.root inputFiles=file:sim.root; rm sim.root"
drpremix2cmd="echo -e \"\nStart PREMIXRAW to AOD (DRPremix 2/2)\n\"; cd $cmsswDRPremixDir; cmsenv; cd -; cmsRun $cfgDir/premixraw_to_aod.py outputFile=aod.root inputFiles=file:raw.root; rm raw.root"
minicmd="echo -e \"\nStart AOD to MINIAOD (MiniAODv6)\n\"; cd $cmsswMiniNanoDir; cmsenv; cd -; cmsRun $cfgDir/aod_to_miniaod.py outputFile=miniaod.root inputFiles=file:aod.root; rm aod.root"
nanocmd="echo -e \"\nStart MINIAOD to NANOAOD (NanoAODv15)\n\"; cd $cmsswMiniNanoDir; cmsenv; cd -; cmsRun $cfgDir/miniaod_to_nanoaod.py outputFile=nanoaod.root inputFiles=file:miniaod.root; rm miniaod.root"
if [[ "$myOutputDir" == "/eos/"* ]]; then
  copycmd="xrdcp nanoaod.root root://eosuser.cern.ch/$myOutputDir/nanoaod_$2.root"
else
  copycmd="mv nanoaod.root $myOutputDir/nanoaod_$2.root"
fi
cmd="cmssw-el8 -- \"source /cvmfs/cms.cern.ch/cmsset_default.sh; source /cvmfs/cms.cern.ch/common/crab-setup.sh; $relinkcmd; $lhegscmd; $drpremix1cmd; $drpremix2cmd; $minicmd; $nanocmd; $copycmd\""
echo $cmd
cmssw-el8 -- "source /cvmfs/cms.cern.ch/cmsset_default.sh; source /cvmfs/cms.cern.ch/common/crab-setup.sh; $relinkcmd; $lhegscmd; $drpremix1cmd; $drpremix2cmd; $minicmd; $nanocmd; $copycmd"
