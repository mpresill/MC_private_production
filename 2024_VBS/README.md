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
  run.jdl                 # per-sample: paths, proxy, queue count (production, 10000 jobs)
  test.jdl                # per-sample: same but queue 1, NEVENTS=2 (smoke test)
  CMSSW_14_0_21_patch4.tar.gz / CMSSW_14_0_22.tar.gz / CMSSW_15_0_17.tar.gz
  condor/{err,out,logs}/  # condor log destinations (empty, gitignored contents)
```

`run.sh`, `submit.sh`, and all step scripts except `lhe-gen-sim.py` are byte-identical
across all 10 samples (verified via checksum) — only `lhe-gen-sim.py` (the physics
process) and `run.jdl` (paths/queue) differ per sample. If you need to fix a bug in the
common chain logic, you currently have to do it in all 10 `run.sh` copies (kept this
way deliberately, matching Jing's original per-sample-independent layout).

## External dependencies (not copied here)

- **Gridpacks**: each `lhe-gen-sim.py` reads its process gridpack from
  `/eos/user/j/jinw/VBS_semilep/*.tar.xz`. This is Jing's EOS area — access already
  verified working from this account. If that ever breaks, ask Jing.
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

## Events per sample and job count

Target: **5,000,000 events per sample.**

- Events per job: `NEVENTS` env var, default `500` (set in `run.sh`, unchanged from
  Jing's setup).
- Job count: `queue 10000` in each `run.jdl` (500 × 10,000 = 5,000,000).
- `test.jdl` overrides to `NEVENTS=2`, `queue 1` for a smoke test.

**This has not been validated at full scale.** The only timing data available is
Jing's 2-event smoke test (~12 minutes wall time, dominated by untarring/relinking the
3 CMSSW releases, not by event processing). `+JobFlavour = "tomorrow"` gives each job
a 1-day wall-time budget — before mass-submitting, run one job at the real per-job
event count and check it comfortably finishes within that:

```
cd 2024_VBS/<any-sample>
NEVENTS=500 ./run.sh /tmp/test_out 0
```

(or submit `test.jdl` with `environment = "NEVENTS=500"` edited in, via condor, to
test on a worker node rather than locally). If 500 events/job is too slow for a
1-day job, lower `NEVENTS` and raise `queue` proportionally (product must stay at
5,000,000) — or bump `+JobFlavour` to `"testmatch"` (3 days).

10 samples × 10,000 jobs = 100,000 jobs total if submitted as-is. Worth checking your
group's HTCondor fair-share/quota before submitting all 10 at once.

## Submitting

```
cd 2024_VBS/<sample>
./submit.sh /eos/path/to/your/output/dir
```

`submit.sh` refuses to run if the destination directory already exists, to avoid
overwriting output by accident. Output files land as `nanoaod_<Process>.root`.

Before submitting, make sure your grid proxy is valid — `run.jdl` currently points
`x509userproxy` at `/afs/cern.ch/user/m/mpresill/.globus/x509up`. Renew with
`voms-proxy-init` (with the CMS VOMS extension) if needed.
