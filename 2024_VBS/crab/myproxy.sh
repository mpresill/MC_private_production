#!/bin/bash
# Stores a 30-day credential on CRAB's MyProxy server (asks for the grid pass phrase).
# Needed once a month before submitting; runs in the el8 submission area.
cd "$(dirname "$(readlink -f "$0")")"
cmssw-el8 -- "source /cvmfs/cms.cern.ch/cmsset_default.sh; cd CMSSW_14_0_21_patch4/src && eval \`scramv1 runtime -sh\` && cd ../.. && source /cvmfs/cms.cern.ch/common/crab-setup.sh && crab createmyproxy"
