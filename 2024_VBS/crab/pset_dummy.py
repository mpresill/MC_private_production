# Placeholder for CRAB: the real work is done by crab_job.sh (scriptExe). CRAB still
# needs a PSet, and crab_job.sh runs it at the end to produce the job report.
import FWCore.ParameterSet.Config as cms

process = cms.Process('DUMMY')
process.source = cms.Source('EmptySource')
process.maxEvents = cms.untracked.PSet(input=cms.untracked.int32(1))
# CRAB requires this to match JobType.numCores, which crab_cfg.py sets from NTHREADS
import os
process.options.numberOfThreads = int(os.environ.get('NTHREADS', '2'))
