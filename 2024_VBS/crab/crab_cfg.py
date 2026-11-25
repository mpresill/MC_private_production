# CRAB config for one task of the 2024_VBS campaign: NJOBS jobs of one sample,
# job indices JOBOFFSET .. JOBOFFSET+NJOBS-1. Submit by hand:
#   SAMPLE=ssWWunpolarized JOBOFFSET=0 NJOBS=5 NEVENTS=100 TAG=crabtest crab submit -c crab_cfg.py
# Submit from the el8 CMSSW area made by setup.sh, so jobs run on el8 and run.sh
# needs no nested container.
import os
import re
from CRABClient.UserUtilities import config

here = os.path.dirname(os.path.abspath(__file__))
sample = os.environ['SAMPLE']
joboffset = int(os.environ['JOBOFFSET'])
njobs = int(os.environ['NJOBS'])
nevents = int(os.environ['NEVENTS'])
nthreads = int(os.environ.get('NTHREADS', '2'))
# must stay the same for the whole campaign, see run.sh
seedoffset = int(os.environ.get('SEEDOFFSET', '100000'))
tag = os.environ['TAG']
outbase = os.environ.get('OUTBASE', '/store/group/lnujj/VVJJ_Private_Production_2024')
gridpackdir = os.environ.get('GRIDPACKDIR', '/store/group/lnujj/VVJJ_Private_Production_2024/gridpacks')

sampledir = os.path.normpath(os.path.join(here, '..', sample))
lhecfg = open(os.path.join(sampledir, 'lhe-gen-sim.py')).read()
gridpack = os.path.basename(re.search(r"args = cms.vstring\('([^']+\.tar\.xz)'\)", lhecfg).group(1))

config = config()

config.General.requestName = f'{sample}_{tag}'[:100]
config.General.workArea = os.path.join(here, 'tasks')
config.General.transferOutputs = True
config.General.transferLogs = False

config.JobType.pluginName = 'PrivateMC'
config.JobType.psetName = os.path.join(here, 'pset_dummy.py')
config.JobType.scriptExe = os.path.join(here, 'crab_job.sh')
config.JobType.scriptArgs = [
    f'JOBOFFSET={joboffset}', f'NEVENTS={nevents}', f'NTHREADS={nthreads}',
    f'SEEDOFFSET={seedoffset}', f'GRIDPACK_URL=root://cmseos.fnal.gov/{gridpackdir}/{gridpack}',
]
commondir = os.path.normpath(os.path.join(here, '..', 'common'))
config.JobType.inputFiles = [os.path.join(commondir, f) for f in (
    'CMSSW_14_0_21_patch4.tar.gz', 'CMSSW_14_0_22.tar.gz', 'CMSSW_15_0_17.tar.gz',
    'gen-sim_to_premixraw.py')] + [os.path.join(sampledir, f) for f in (
    'run.sh', 'lhe-gen-sim.py', 'premixraw_to_aod.py', 'aod_to_miniaod.py',
    'miniaod_to_nanoaod.py')]
config.JobType.outputFiles = ['nanoaod.root']
config.JobType.numCores = nthreads
# CRAB allows at most 2500 MB per core, so 5000 MB is the limit at 2 threads. The CRAB
# test (100 events / 2 threads) peaked at 5143 MB: check the margin at production size.
config.JobType.maxMemoryMB = 2500 * nthreads
config.JobType.maxJobRuntimeMin = int(os.environ.get('MAXRUNTIME', '1315'))

# one dummy event per job: the real event count is NEVENTS, handled by run.sh
config.Data.outputPrimaryDataset = sample
config.Data.splitting = 'EventBased'
config.Data.unitsPerJob = 1
config.Data.totalUnits = njobs
config.Data.outLFNDirBase = outbase
config.Data.outputDatasetTag = tag
config.Data.publication = False

config.Site.storageSite = 'T3_US_FNALLPC'
