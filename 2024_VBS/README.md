# 2024_VBS

Private production chain for 2024 VBS signal + QCD-VV background samples, adapted from
Jing's (jinw) working setup at:

```
/afs/cern.ch/work/j/jinw/public/gen_VBS/24v15
```

She confirmed the chain works end-to-end (LHE-GEN-SIM through NanoAOD) via a 2-event
smoke test per sample. This folder is her scripts copied over with the paths, proxy,
and job count adjusted to run under this account. **The per-sample workflow itself was
left as-is, not restructured to match the rest of this repo** — see "How this differs
from the rest of the repo" below before editing.

## Samples

5 signal / 5 QCD-VV background pairs:

| Signal | QCD-VV background |
|---|---|
| `osWWunpolarized_Wptojj_Wmtolv` | `osWWunpolarized_Wptojj_Wmtolv_QCD` |
| `osWWunpolarized_Wptolv_Wmtojj` | `osWWunpolarized_Wptolv_Wmtojj_QCD` |
| `ssWWunpolarized` | `ssWWunpolarized_QCD` |
| `WZunpolarized_Wmtolv_Ztojj` | `WZunpolarized_Wmtolv_Ztojj_QCD` |
| `WZunpolarized_Wptolv_Ztojj` | `WZunpolarized_Wptolv_Ztojj_QCD` |

Each folder is self-contained: one `condor_submit` per sample runs the full chain
(LHEGS → PREMIXRAW → AOD → MiniAOD → NanoAOD) inside a single job, per event.

## How this differs from the rest of the repo

Everywhere else in this repo, generation is either driven via CRAB (see the top-level
`crab_sub_*.py` / README) or via a condor wrapper that chains separately-submitted
per-step jobs (see `runners/`, `wrapper.sh`). This folder instead runs the **entire
chain (LHEGS → PREMIXRAW → AOD → MiniAOD → NanoAOD) inside a single condor job**,
via `run.sh`, under a `cmssw-el8` singularity, using CMSSW releases `14_0_21_patch4`,
`14_0_22` and `15_0_17` (Run3_2024 / 140X, not the UL 10_6_x releases used elsewhere in
this repo). One job = one gridpack-seeded event chunk = one output NanoAOD file.

## Layout of each sample folder

```
<sample>/
  lhe-gen-sim.py          # per-sample: physics process / gridpack (see below)
  gen-sim_to_premixraw.py # common step (see note on git tracking below)
  premixraw_to_aod.py     # common step
  aod_to_miniaod.py       # common step
  miniaod_to_nanoaod.py   # common step
  run.sh                  # runs the full chain for one job; identical across samples
  submit.sh               # wraps condor_submit; identical across samples
  run.jdl                 # per-sample: paths, proxy, queue count (production, 5000 jobs)
  test.jdl                # per-sample: same but queue 1 (single-job test)
  CMSSW_14_0_21_patch4.tar.gz / CMSSW_14_0_22.tar.gz / CMSSW_15_0_17.tar.gz
  condor/{err,out,logs}/  # condor log destinations (empty, gitignored contents)
```

and one script at the top of `2024_VBS/`:

```
submitter.sh              # submits the whole campaign (all 10 samples) in one shot
submitted_<timestamp>.txt # written by submitter.sh: sample -> cluster id bookkeeping
```

`run.sh`, `submit.sh`, and all step scripts except `lhe-gen-sim.py` are byte-identical
across all 10 samples (verified via checksum) — only `lhe-gen-sim.py` (the physics
process) and `run.jdl` (paths/queue) differ per sample. If you need to fix a bug in the
common chain logic, you currently have to do it in all 10 `run.sh` copies (kept this
way deliberately, matching Jing's original per-sample-independent layout).

## External dependencies (not copied here)

- **Gridpacks**: one folder on FNAL EOS,
  `/store/group/lnujj/VVJJ_Private_Production_2024/gridpacks/`, read by every job
  (lxplus condor and CRAB). `lhe-gen-sim.py` holds the `root://cmseos.fnal.gov/...`
  path, and `run.sh` downloads that file into the job before the chain starts. To change
  a sample's gridpack, copy the new one there and edit that line. The two ssWW samples
  use the November 2026 decay-chain (`_DC_`) gridpacks; the other 8 are copies of
  Jing's originals from `/eos/user/j/jinw/VBS_semilep/` (adler32 checked).
- **`build/` (CMSSW source trees)**: Jing's `24v15/build/` directory (237MB of
  compiled CMSSW checkouts, used to produce the three `.tar.gz` releases below) was
  **not copied** — only the resulting tarballs were, matching how this repo already
  treats CMSSW release areas (see root `.gitignore`).

## What's tracked in git vs. local-only

Per the root `.gitignore`:
- `CMSSW_*.tar.gz` in every sample folder: **not tracked** (same as elsewhere in this
  repo). Present locally right now; if missing after a fresh clone, copy them back
  from `/afs/cern.ch/work/j/jinw/public/gen_VBS/24v15/<sample>/` or rebuild from the
  `build/` area there.
- `gen-sim_to_premixraw.py`: this file is ~80MB (it embeds the full PreMix pileup file
  list) and is byte-identical across all 10 samples. Only the copy in
  `osWWunpolarized_Wptojj_Wmtolv/` is tracked in git, as a reference; the other 9 are
  gitignored but present locally. If you re-clone this repo, copy that file into the
  other 9 sample folders before submitting (or regenerate it — the `cmsDriver`
  command used to produce it is in the file's own header comment).
- `condor/{err,out,logs}/*`: gitignored (job logs), `.gitkeep` placeholders keep the
  directories present so `condor_submit` doesn't need to create them first.

## Random seeds, event IDs and output format

**Every job gets its own random seed, and every random engine in the chain is seeded
from it.** `run.sh` sets `seed = 1 + <job index> + SEEDOFFSET` and passes it to the three
steps that use random numbers:

| Step | What is seeded from the job seed |
|---|---|
| `lhe-gen-sim.py` | gridpack/MadGraph (`externalLHEProducer` = the job seed itself), Pythia, vertex smearing, Geant4 |
| `gen-sim_to_premixraw.py` | pileup premixing (`mixData`), muon/PPS digitisers |
| `premixraw_to_aod.py` | HCAL/ES reco engines |

Each engine's seed is `(crc32("<process>:<engine>") + 1000003 x seed) % 900000000 + 1`,
so seeds differ between jobs, between engines and between steps. The code is at the
end of each of the three configs; the configs refuse to run without `randomSeed`.

**Event IDs are unique across jobs.** Run number stays 1; job `seed` gets lumi blocks
starting at `1 + (seed-1) x ceil(nevents/5)` and event numbers starting at
`1 + (seed-1) x nevents`, so `(run, lumi, event)` never repeats within a production.

**`SEEDOFFSET` (default 100000, set in `run.sh`) keeps productions apart.** Two
productions of the same gridpack with the same seeds contain the *same events*. Anyone
else producing these samples from the same gridpacks must use a different offset.

**Output is flat NanoAOD** (`NanoAODOutputModule`, an `Events` TTree with `Jet_pt`,
`LHEPart_pt`, ... branches), readable directly with ROOT, uproot or RDataFrame.

> **Bug fixed in Nov 2026 — the Aug 2026 campaign output is unusable.** The configs
> inherited from `24v15` hardcoded `externalLHEProducer.initialSeed=int(1)` (the
> `options.randomSeed` in the file's header comment was never applied), left every other
> engine at its cmsDriver default and gave every job lumis 1-200 / events 1-1000. Every
> file of a sample therefore contained the **same 1,000 LHE events** with the same event
> IDs (shower/detector/pileup still varied, but only through multithreaded event
> scheduling). The NanoAOD was also written in EDM format (`PoolOutputModule`). All 10
> samples of that campaign must be regenerated.

## Events per sample and job count

Target: **5,000,000 events per sample**, i.e. `nevents x njobs = 5,000,000`.
`submitter.sh` refuses to submit unless that product is exactly 5,000,000 (`--force`
overrides).

Current setting: **1000 events/job x 5000 jobs** per sample = 50,000 jobs for all 10,
run with **2 threads** (`nthreads=2 ncpus=2`, the default in `run.jdl`/`test.jdl`/`submitter.sh`).

Measured condor test jobs (`ssWWunpolarized`, Aug 2026):

| | 500 ev, 1 thread | 1000 ev, 2 threads (production config) |
|---|---|---|
| wall time | 4h 08m (14,868 s) | **6h 17m (22,625 s)**, of a 24h `tomorrow` budget |
| peak memory | 3,765 MB | 4,541 MB (of the 6000 MB slot) |
| peak disk | 1.45 GB | 2.9 GB (of the 5.7 GB requested) |
| NanoAOD size | 9.35 MB (18.7 kB/event) | 15.7 MB (15.7 kB/event) |
| CPU used / allocated | 0.99 of 2 cores | 1.97 of 2 cores |

Why 1000 x 5000 and not 500 x 10000: `MAX_JOBS_PER_OWNER` on the CERN schedds is
**100,000**, so 10 samples x 10,000 jobs would sit exactly on the cap with no room to
resubmit failures — and it doubles the fixed per-job cost (77 MB of input transfer plus
~6 min of untar/relink). 2000 ev/job would leave too little margin under `tomorrow`.

**Wall time is not the same for every sample.** The numbers above are
`ssWWunpolarized` (median 5 h/job, all 5000 jobs done). The two opposite-sign WW
samples are ~4.5x slower: measured medians of **~23 h/job**, i.e. right on top of the
24 h `tomorrow` budget. In the Aug 2026 campaign that killed 4985/5000 jobs of
`osWWunpolarized_Wptojj_Wmtolv` and 4835/5000 of `osWWunpolarized_Wptolv_Wmtojj`
("removed by SYSTEM_PERIODIC_REMOVE due to wall time exceeded allowed max", all at
once, ~26 h after the cluster started), while `ssWWunpolarized` finished cleanly.
Slow samples therefore need a bigger budget: `--flavour nextweek` (7 days;
`tomorrow` = 1 day, `testmatch` = 3 days), which sets `+JobFlavour` in the jdl.

**Threads.** CERN slots carve ~3000 MB per core, so `request_memory = 6000` gets a
2-core slot whether `request_cpus` (`ncpus`) asks for 1 or 2 — the second core is
allocated and billed either way. Measured: `nthreads=2` gives a **1.31x** wall-time
speedup over the single-thread-equivalent for 1000 events (not 2x — the LHEGS step,
gridpack → LHE-GEN-SIM, is 66% of wall time and threads poorly; DRPremix2, the
pileup-mixing step, is the next largest at 19%). Peak memory (4,541 MB) has comfortable
headroom under the 6000 MB slot. Since the core is already paid for, this is a real win
at no extra cost, so it's the campaign default.

## Launching the November 2026 campaign (all on lxplus condor)

Two people submit, one group of samples each. Both write to the same output folder
and read the same gridpack folder, and each sample is submitted by one person only,
so job indices (and with them seeds and event IDs) can never collide.

| Who | Samples | Events/job × jobs | Jobs |
|---|---|---|---|
| Matteo | `ssWWunpolarized(_QCD)`, `WZunpolarized_*` (6 samples) | 1,000 × 5,000 | 30,000 |
| Colleague | `osWWunpolarized_*` (4 samples) | 500 × 10,000 | 40,000 |

osWW uses 500 events per job because 1,000-event jobs take ~23 h, too close to the
24 h `tomorrow` limit. Keep `NEVENTS` fixed for a sample once it is submitted: event IDs
are derived from it, so retries must use the same value (`--resubmit` does).

**Output:** `/eos/uscms/store/group/lnujj/VVJJ_Private_Production_2024_v2/<sample>/nanoaod_<index>.root`

### 0. Once, per person

1. A FNAL computing account linked to your grid certificate (needed to write to FNAL EOS).
2. A copy of this `2024_VBS` folder in your own AFS work area, complete with the inputs
   that git does not hold (the three `CMSSW_*.tar.gz` and `gen-sim_to_premixraw.py` in
   every sample folder). Ask Matteo for the input bundle on FNAL EOS.
3. A proxy: `voms-proxy-init --voms cms --valid 192:00 -out $HOME/.proxy`
4. A write test on the output folder:

   ```
   export X509_USER_PROXY=$HOME/.proxy
   xrdfs root://cmseos.fnal.gov mkdir /store/group/lnujj/VVJJ_Private_Production_2024_v2/writetest_$USER \
     && xrdfs root://cmseos.fnal.gov rmdir /store/group/lnujj/VVJJ_Private_Production_2024_v2/writetest_$USER \
     && echo "write OK"
   ```

### 1. Check, then submit

```
cd 2024_VBS
# Matteo
./submitter.sh --samples "ssWWunpolarized ssWWunpolarized_QCD WZunpolarized_Wmtolv_Ztojj WZunpolarized_Wmtolv_Ztojj_QCD WZunpolarized_Wptolv_Ztojj WZunpolarized_Wptolv_Ztojj_QCD" --dry-run
# colleague
./submitter.sh --samples "osWWunpolarized_Wptojj_Wmtolv osWWunpolarized_Wptojj_Wmtolv_QCD osWWunpolarized_Wptolv_Wmtojj osWWunpolarized_Wptolv_Wmtojj_QCD" \
               --nevents 500 --njobs 10000 --log-sample none --dry-run
```

If the dry run passes, run the same command without `--dry-run` and answer `y`.

### 2. While it runs

- `condor_q` shows progress; `submitted_<timestamp>.txt` maps samples to cluster ids.
- Renew the proxy before it expires (same `voms-proxy-init` command). Running jobs
  keep the copy they started with.
- When a sample's jobs have left the queue, re-queue only the missing outputs with the
  same command plus `--resubmit` (and the same `--nevents`/`--njobs`).

## Submitting

### The whole campaign, in one shot

```
cd 2024_VBS
./submitter.sh --dry-run     # run every check, print what would be submitted
./submitter.sh               # same + submit, after a confirmation prompt
```

`submitter.sh` submits all 10 samples to
`/eos/uscms/store/group/lnujj/VVJJ_Private_Production_2024_v2/<sample>` and refuses to
start unless:

1. the proxy (`--proxy`, else `X509_USER_PROXY`, else `$HOME/.proxy`) exists and has
   >24 h left,
2. `nevents x njobs == 5,000,000` per sample,
3. every sample folder has all 8 input files (`gen-sim_to_premixraw.py` is gitignored
   in 9 of the 10 folders — see above),
4. queued + planned jobs fit under `MAX_JOBS_PER_OWNER`.

It writes `submitted_<timestamp>.txt` mapping each sample to its cluster id, for later
`condor_q` / `condor_rm`. Useful options: `--samples "a b"`, `--nevents`/`--njobs`,
`--nthreads`/`--ncpus`, `--base DIR`, `--log-sample NAME|none`, `--flavour NAME`,
`--resubmit` (see [Monitoring and resubmitting](#monitoring-and-resubmitting)), `-y`,
`--force`. `./submitter.sh --help` lists them all.

### A single sample / a single test job

```
cd 2024_VBS/<sample>
./submit.sh <outdir> [jdl file, default run.jdl] [key=value ...]
```

Any `key=value` goes straight to `condor_submit`, so the knobs in the jdl
(`nevents`, `njobs`, `nthreads`, `ncpus`, `keeplog`) can be overridden per submission:

```
cd 2024_VBS/ssWWunpolarized
./submit.sh /eos/uscms/store/group/lnujj/VVJJ_Private_Production_2024/ssWWunpolarized_test \
            test.jdl nevents=1000 nthreads=2 ncpus=2
```

Output files land as `nanoaod_<Process>.root`. `submit.sh` refuses to run if the
destination directory already exists **and is non-empty**, to avoid overwriting output
by accident; if it doesn't exist it is created.

### Output destinations

`run.sh` and `submit.sh` pick the stage-out method from the output path:

| Output path | How the job writes it |
|---|---|
| `/eos/uscms/store/...` or `/store/...` | `xrdcp` to `root://cmseos.fnal.gov/` (FNAL EOS — note the `/eos/uscms` prefix is *not* part of the xrootd namespace and is stripped) |
| `/eos/cms/...` | `xrdcp` to `root://eoscms.cern.ch/` |
| any other `/eos/...` | `xrdcp` to `root://eosuser.cern.ch/` |
| anything else | plain local `mv` |

Writing to FNAL EOS from CERN-submitted condor jobs works over the WAN with a valid
CMS VOMS proxy (verified end-to-end with a 500-event job) — nothing needs to be
submitted from the LPC.

Before submitting, make sure your grid proxy is valid. The jdl files use
`use_x509userproxy = true`, so condor ships whatever `X509_USER_PROXY` points to at
submit time; `submit.sh` and `submitter.sh` default it to `$HOME/.proxy`. Create or renew
it with `voms-proxy-init --voms cms --valid 192:00 -out $HOME/.proxy`. Both scripts
ignore a `X509_USER_PROXY` that points at a non-existent file (lxplus profiles often
preset it to `~/.globus/x509up`). No path in the jdl files is user-specific, so anyone
can submit from their own copy of this folder.

## Job logs

The chain prints ~4 MB of stdout per 1000-event job. At 50,000 jobs that is ~200 GB,
which does not fit in the AFS work quota (100 GB, already ~72% full) — and CERN
schedds reject `/eos` paths for `output`/`error`/`log` (submit requirement `NoEos`),
so the logs cannot simply be pointed elsewhere. Therefore:

- `run.sh` captures the whole chain into `job_<Process>.log` inside the job sandbox and
  prints only a **~700 byte summary** (host, seed, events, threads, destination, staged
  file size, wall time, exit code, per-step timestamps) to condor's `output`.
- **On failure** it dumps the matching `Exception|Fatal|Error` lines plus the last 300
  log lines to condor's `error`, and copies the gzipped full log to
  `<outdir>/logs/job_<Process>.log.gz` on EOS.
- **`keeplog=1`** archives the gzipped full log for *every* job, not just failures.
  `submitter.sh --log-sample <name>` sets it for one reference sample (default
  `ssWWunpolarized`); the other 9 keep logs for failures only.
- `run.sh` also verifies the staged NanoAOD exists and is non-empty, and exits 65 if
  not, so a silently lost output becomes a visible held/failed job.
- Each cluster writes a **single** condor `log` file (`condor/logs/log_<Cluster>.log`),
  not one per job: CERN dropped support for per-job log files in January 2026
  (submit requirement `NoProcIdInLog`) because they make the schedd unresponsive.

## Monitoring and resubmitting

```
condor_q                                   # overview by batch name
condor_q -better-analyze <cluster>         # why isn't it matching?
tail 2024_VBS/<sample>/condor/out/out.<N>  # the ~700 byte summary of one job
xrdfs root://cmseos.fnal.gov ls -l /store/group/lnujj/VVJJ_Private_Production_2024/<sample>
```

A missing `nanoaod_<N>.root` means job `<N>` failed; its log is at
`<outdir>/logs/job_<N>.log.gz`.

### Resubmitting the failures

```
./submitter.sh --resubmit --samples "osWWunpolarized_Wptojj_Wmtolv" --dry-run
./submitter.sh --resubmit --samples "osWWunpolarized_Wptojj_Wmtolv"
```

`--resubmit` lists `<base>/<sample>` on EOS, works out which of the `0..njobs-1`
indices have no non-zero-size `nanoaod_<index>.root`, writes them to
`<sample>/condor/resubmit_<stamp>.txt`, and queues exactly those. A retried job keeps
its **original index**, so it reuses the same random seed (`seed = index + 1 + SEEDOFFSET`) and
overwrites its own output only — a retry can never duplicate another job's events.
Bookkeeping goes to `resubmitted_<stamp>.txt`, same format as `submitted_<stamp>.txt`.

Notes:

- `--njobs` must stay at the value the sample was originally submitted with (it
  defines the index space that is being checked for holes), which is why `--resubmit`
  still enforces the 5M-event check.
- It refuses to run while jobs of the same sample are still in the queue, since two
  clusters would race for the same output files (`--force` overrides).
- `submit.sh`'s non-empty-directory guard is bypassed on purpose here: `--resubmit`
  calls `condor_submit` directly with `joblist=...`. That guard still protects fresh
  submissions.
- The same mechanism by hand, for a one-off:
  `printf '17\n42\n' > condor/retry.txt && condor_submit outdir=<outdir> joblist=condor/retry.txt run.jdl`

## Submitting with CRAB (tested, not used)

**Not used for the November 2026 campaign, which runs entirely on lxplus condor.**
A 1,000-event osWW test showed why: jobs peak at about 5,050 MB, CRAB allows at most
2,500 MB per core, and the 2-core jobs were killed for memory (exit code 50660).
Using CRAB would need 3 cores per job (7,500 MB), which is untested.

`crab/` runs the same chain as a CRAB task, so jobs go to the grid instead of the
lxplus condor pool.

- **How a job runs.** `crab_job.sh` is the CRAB `scriptExe`. It turns the CRAB job
  number into the job index (`JOBOFFSET + job number - 1`), downloads the sample's
  gridpack, runs `run.sh` in a clean environment, and hands `nanoaod.root` back to
  CRAB for stage-out. `pset_dummy.py` exists only because CRAB needs a PSet and a job
  report.
- **No nested container.** Tasks are submitted from the el8 release area made by
  `crab/setup.sh`, so jobs run on el8. `run.sh` then runs the chain directly instead
  of through `cmssw-el8` (it checks `/etc/os-release`).
- **Gridpacks.** Grid jobs can't read the original CERN EOS user area with a grid certificate, so
  the gridpacks are copied (with adler32 check) to
  `/store/group/lnujj/VVJJ_Private_Production_2024/gridpacks/` on FNAL EOS. Each job
  fetches its own copy. `lhe-gen-sim.py` takes it through the `gridpack=` option;
  without the option it uses the original path, so lxplus condor is unchanged.
- **Output.** `/store/group/lnujj/VVJJ_Private_Production_2024_v2/<sample>/<tag>/<date>/0000/nanoaod_<CRAB job number>.root`.
- **Job indices must never overlap within a sample.** Each task of a sample covers its
  own range (`JOBOFFSET` .. `JOBOFFSET + NJOBS - 1`), with the same `SEEDOFFSET` and the
  same `NEVENTS` for the whole sample. Otherwise two jobs share seeds and event IDs.

Test submission (from lxplus, valid proxy):

```bash
cd crab && ./setup.sh   # once
cmssw-el8   # then, inside:
cd CMSSW_14_0_21_patch4/src && cmsenv && cd ../..
source /cvmfs/cms.cern.ch/common/crab-setup.sh
SAMPLE=ssWWunpolarized JOBOFFSET=0 NJOBS=5 NEVENTS=100 SEEDOFFSET=900000 TAG=crabtest \
  crab submit -c crab_cfg.py
```

The test uses `SEEDOFFSET=900000` so its events can't coincide with production
(offset 100000).

The first submission also needs a 30-day credential on CRAB's MyProxy server. Run
`crab/myproxy.sh` once a month in a normal terminal, since it asks for the grid pass
phrase.

On a fresh clone, `gen-sim_to_premixraw.py` exists only in
`osWWunpolarized_Wptojj_Wmtolv/`. Copy it to the other 9 sample folders before
submitting (the file is identical across samples).
