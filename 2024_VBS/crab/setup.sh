#!/bin/bash
# One-time: create the el8 CMSSW area that CRAB tasks are submitted from.
cd "$(dirname "$0")"
cmssw-el8 -- "source /cvmfs/cms.cern.ch/cmsset_default.sh; [ -d CMSSW_14_0_21_patch4 ] || scramv1 project CMSSW CMSSW_14_0_21_patch4"
