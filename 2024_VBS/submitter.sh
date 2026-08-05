#!/bin/bash
#
# One-shot submitter for the whole 2024_VBS campaign: submits every sample with
# nevents x njobs = 5,000,000 events, running all the pre-flight checks first.
#
#   ./submitter.sh --dry-run     # show what would be submitted, submit nothing
#   ./submitter.sh               # submit everything (asks for confirmation)
#
set -u

baseDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ---------------------------------------------------------------- defaults ---
BASE=/eos/uscms/store/group/lnujj/VVJJ_Private_Production_2024
SAMPLES="osWWunpolarized_Wptojj_Wmtolv \
         osWWunpolarized_Wptojj_Wmtolv_QCD \
         osWWunpolarized_Wptolv_Wmtojj \
         osWWunpolarized_Wptolv_Wmtojj_QCD \
         ssWWunpolarized \
         ssWWunpolarized_QCD \
         WZunpolarized_Wmtolv_Ztojj \
         WZunpolarized_Wmtolv_Ztojj_QCD \
         WZunpolarized_Wptolv_Ztojj \
         WZunpolarized_Wptolv_Ztojj_QCD"
NEVENTS=1000
NJOBS=5000
NTHREADS=1
NCPUS=1
LOGSAMPLE=ssWWunpolarized   # the one sample that archives every job log to EOS
JDL=run.jdl
# the proxy that matters is the one the jdl ships to the jobs, not whatever
# X509_USER_PROXY happens to point at in this shell
PROXY=
TARGET=5000000              # events per sample
DRYRUN=0
YES=0
FORCE=0

usage () {
  cat <<EOF
Usage: ./submitter.sh [options]

  --base DIR          base output directory (default: $BASE)
                      each sample is written to <base>/<sample>
  --samples "a b c"   subset of samples (default: all 10)
  --nevents N         events per job    (default: $NEVENTS)
  --njobs N           jobs per sample   (default: $NJOBS)
  --nthreads N        cmsRun threads    (default: $NTHREADS)
  --ncpus N           CPUs requested per job (default: $NCPUS; set = --nthreads
                      when running multithreaded)
  --log-sample NAME   sample archiving every job log to EOS, or "none"
                      (default: $LOGSAMPLE)
  --jdl FILE          jdl to submit     (default: $JDL)
  --dry-run           run all checks and print the commands, submit nothing
  --force             allow nevents x njobs != $TARGET events per sample
  -y, --yes           do not ask for confirmation
  -h, --help          this message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base)        BASE=$2 ; shift 2 ;;
    --samples)     SAMPLES=$2 ; shift 2 ;;
    --nevents)     NEVENTS=$2 ; shift 2 ;;
    --njobs)       NJOBS=$2 ; shift 2 ;;
    --nthreads)    NTHREADS=$2 ; shift 2 ;;
    --ncpus)       NCPUS=$2 ; shift 2 ;;
    --log-sample)  LOGSAMPLE=$2 ; shift 2 ;;
    --jdl)         JDL=$2 ; shift 2 ;;
    --proxy)       PROXY=$2 ; shift 2 ;;
    --dry-run)     DRYRUN=1 ; shift ;;
    --force)       FORCE=1 ; shift ;;
    -y|--yes)      YES=1 ; shift ;;
    -h|--help)     usage ; exit 0 ;;
    *)             echo "Unknown option: $1" ; usage ; exit 1 ;;
  esac
done

fail () { echo "ERROR: $*" >&2 ; exit 1 ; }

# ------------------------------------------------------------ pre-flight ---
echo "=== pre-flight checks ==="

# 0. take the proxy path straight out of the jdl, so the check can never drift
#    from what condor actually ships to the jobs
if [ -z "$PROXY" ]; then
  firstSample=$(echo $SAMPLES | awk '{print $1}')
  PROXY=$(awk -F= '/^[[:space:]]*x509userproxy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' \
            "$baseDir/$firstSample/$JDL" 2>/dev/null)
  [ -n "$PROXY" ] || PROXY=/afs/cern.ch/user/m/mpresill/.proxy
fi

# 1. grid proxy, with enough life left to matter
[ -r "$PROXY" ] || fail "no readable proxy at $PROXY
       voms-proxy-init --voms cms --valid 192:00 -out $PROXY"
if ! voms-proxy-info -file "$PROXY" -exists -valid 24:00 > /dev/null 2>&1; then
  fail "proxy $PROXY is missing, expired, or has less than 24h left
       voms-proxy-init --voms cms --valid 192:00 -out $PROXY"
fi
proxyleft=$(voms-proxy-info -file "$PROXY" -timeleft 2>/dev/null)
echo "  proxy      : OK ($((proxyleft/3600))h left)"
export X509_USER_PROXY=$PROXY

# 2. the whole point of this script: really submitting 5M events per sample
total=$((NEVENTS * NJOBS))
if [ "$total" -ne "$TARGET" ]; then
  if [ "$FORCE" -eq 1 ]; then
    echo "  events     : WARNING $NEVENTS x $NJOBS = $total events/sample (target $TARGET), --force given"
  else
    fail "$NEVENTS events/job x $NJOBS jobs = $total events/sample, but the target is $TARGET.
       Adjust --nevents / --njobs, or pass --force if you really mean it."
  fi
else
  echo "  events     : OK $NEVENTS x $NJOBS = $total events/sample"
fi

# 3. every sample folder is complete (gen-sim_to_premixraw.py is gitignored in 9 of 10)
needed="CMSSW_14_0_21_patch4.tar.gz CMSSW_14_0_22.tar.gz CMSSW_15_0_17.tar.gz \
        lhe-gen-sim.py gen-sim_to_premixraw.py premixraw_to_aod.py \
        aod_to_miniaod.py miniaod_to_nanoaod.py run.sh submit.sh $JDL"
nsamples=0
for s in $SAMPLES; do
  [ -d "$baseDir/$s" ] || fail "no such sample directory: $baseDir/$s"
  for f in $needed; do
    [ -s "$baseDir/$s/$f" ] || fail "$s/$f is missing or empty (see README: some inputs are gitignored)"
  done
  for d in condor/err condor/out condor/logs; do
    [ -d "$baseDir/$s/$d" ] || mkdir -p "$baseDir/$s/$d"
  done
  nsamples=$((nsamples + 1))
done
echo "  inputs     : OK $nsamples sample(s) complete"

# 4. room in the queue
maxjobs=$(condor_config_val -schedd MAX_JOBS_PER_OWNER 2>/dev/null)
[[ "$maxjobs" =~ ^[0-9]+$ ]] || maxjobs=100000
inqueue=$(condor_q -totals 2>/dev/null | awk -v u="$(whoami):" '$1=="Total" && $3==u {print $4; exit}')
[[ "$inqueue" =~ ^[0-9]+$ ]] || inqueue=0
planned=$((NJOBS * nsamples))
if [ $((inqueue + planned)) -gt "$maxjobs" ]; then
  fail "$inqueue jobs already queued + $planned planned > MAX_JOBS_PER_OWNER ($maxjobs)"
fi
echo "  queue      : OK $inqueue queued + $planned planned <= $maxjobs"

# ---------------------------------------------------------------- summary ---
echo
printf "%-36s %9s %8s %12s  %s\n" SAMPLE EV/JOB JOBS EVENTS DESTINATION
for s in $SAMPLES; do
  printf "%-36s %9d %8d %12d  %s\n" "$s" "$NEVENTS" "$NJOBS" "$total" "$BASE/$s"
done
echo
echo "  threads/job    : $NTHREADS  (request_cpus = $NCPUS)"
echo "  full job logs  : $([ "$LOGSAMPLE" = none ] && echo "failures only" || echo "every job of $LOGSAMPLE (-> <outdir>/logs/), failures elsewhere")"
echo "  jdl            : $JDL"
echo "  total jobs     : $((NJOBS * nsamples))"
echo "  total events   : $((total * nsamples))"
echo "  est. output    : ~$(( (total * nsamples) * 187 / 10000000 )) GB   (18.7 kB/event measured)"
echo "  est. wall time : ~$(( total * nsamples * 30 / 3600 )) job-hours (30 s/event measured, single-threaded)"
echo

if [ "$DRYRUN" -eq 1 ]; then
  echo "=== dry run, submitting nothing ==="
  for s in $SAMPLES; do
    keeplog=0 ; [ "$s" = "$LOGSAMPLE" ] && keeplog=1
    echo "(cd $baseDir/$s && ./submit.sh $BASE/$s $JDL nevents=$NEVENTS njobs=$NJOBS nthreads=$NTHREADS ncpus=$NCPUS keeplog=$keeplog)"
  done
  exit 0
fi

if [ "$YES" -ne 1 ]; then
  read -r -p "Submit $((NJOBS * nsamples)) jobs? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "aborted" ; exit 1 ;;
  esac
fi

# ------------------------------------------------------------- submission ---
record=$baseDir/submitted_$(date -u +%Y%m%dT%H%M%SZ).txt
{
  echo "# submitted $(date -u +'%Y-%m-%d %H:%M:%S UTC') by $(whoami)"
  echo "# sample cluster njobs nevents nthreads ncpus outdir"
} > "$record"

nok=0
nbad=0
for s in $SAMPLES; do
  keeplog=0 ; [ "$s" = "$LOGSAMPLE" ] && keeplog=1
  echo "=== $s ==="
  out=$(cd "$baseDir/$s" && ./submit.sh "$BASE/$s" "$JDL" \
          nevents=$NEVENTS njobs=$NJOBS nthreads=$NTHREADS ncpus=$NCPUS keeplog=$keeplog 2>&1)
  echo "$out"
  cluster=$(echo "$out" | sed -n 's/.*submitted to cluster \([0-9]*\).*/\1/p' | tail -1)
  if [ -n "$cluster" ]; then
    echo "$s $cluster $NJOBS $NEVENTS $NTHREADS $NCPUS $BASE/$s" >> "$record"
    nok=$((nok + 1))
  else
    echo "$s FAILED - - - - $BASE/$s" >> "$record"
    nbad=$((nbad + 1))
  fi
done

echo
echo "=== $nok sample(s) submitted, $nbad failed ==="
echo "record written to $record"
echo "monitor with:  condor_q"
[ "$nbad" -eq 0 ] || exit 1
