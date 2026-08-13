# One-shot submitter for the whole 2024_VBS campaign: submits every sample with
# nevents x njobs = 5,000,000 events, running all the pre-flight checks first.
#
#   ./submitter.sh --dry-run     # show what would be submitted, submit nothing
#   ./submitter.sh               # submit everything (asks for confirmation)
#
# Retries are the same script with --resubmit: it lists what actually landed on
# EOS and re-queues only the job indices whose nanoaod_<index>.root is missing.
#
#   ./submitter.sh --resubmit --samples "osWWunpolarized_Wptojj_Wmtolv" --dry-run
#
set -u

baseDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ---------------------------------------------------------------- defaults ---
BASE=/eos/uscms/store/group/lnujj/VVJJ_Private_Production_2024
SAMPLES="osWWunpolarized_Wptojj_Wmtolv \
         osWWunpolarized_Wptolv_Wmtojj"

NEVENTS=1000
NJOBS=5000
NTHREADS=2
NCPUS=2
LOGSAMPLE=ssWWunpolarized   # the one sample that archives every job log to EOS
JDL=run.jdl
# the proxy that matters is the one the jdl ships to the jobs, not whatever
# X509_USER_PROXY happens to point at in this shell
PROXY=
TARGET=5000000              # events per sample
FLAVOUR=                    # empty: keep the jdl default (tomorrow)
DRYRUN=0
YES=0
FORCE=0
RESUBMIT=0

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
  --flavour NAME      JobFlavour: tomorrow (1d), testmatch (3d), nextweek (7d)
                      (default: whatever the jdl says, i.e. tomorrow)
  --resubmit          re-queue only the jobs whose nanoaod_<index>.root is
                      missing from <base>/<sample>, keeping each job's original
                      index (so its random seed and output name are unchanged)
  --dry-run           run all checks and print the commands, submit nothing
  --force             allow nevents x njobs != $TARGET events per sample, and
                      with --resubmit, submit even if jobs of the same sample
                      are still in the queue
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
    --flavour)     FLAVOUR=$2 ; shift 2 ;;
    --proxy)       PROXY=$2 ; shift 2 ;;
    --resubmit)    RESUBMIT=1 ; shift ;;
    --dry-run)     DRYRUN=1 ; shift ;;
    --force)       FORCE=1 ; shift ;;
    -y|--yes)      YES=1 ; shift ;;
    -h|--help)     usage ; exit 0 ;;
    *)             echo "Unknown option: $1" ; usage ; exit 1 ;;
  esac
done

fail () { echo "ERROR: $*" >&2 ; exit 1 ; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
tmpdir=$(mktemp -d) || fail "cannot create a temporary directory"
trap 'rm -rf "$tmpdir"' EXIT

# Job indices already on EOS for a sample: nanoaod_<index>.root with a non-zero
# size, the same criterion run.sh uses to call a job successful. Returns non-zero
# if the directory cannot be listed at all, so a dead redirector or a missing
# proxy can never be mistaken for "nothing landed, resubmit everything".
# Same path -> redirector mapping as submit.sh and run.sh.
done_indices () {
  local outdir=$1 redirector remoteDir raw=$tmpdir/ls.$$
  case "$outdir" in
    /eos/uscms/*) redirector=root://cmseos.fnal.gov ; remoteDir=${outdir#/eos/uscms} ;;
    /store/*)     redirector=root://cmseos.fnal.gov ; remoteDir=$outdir ;;
    /eos/cms/*)   redirector=root://eoscms.cern.ch  ; remoteDir=$outdir ;;
    /eos/*)       redirector=root://eosuser.cern.ch ; remoteDir=$outdir ;;
    *)            redirector=""                     ; remoteDir=$outdir ;;
  esac
  if [ -n "$redirector" ]; then
    # xrdfs ls -l: perms owner group size date time path
    xrdfs "$redirector" ls -l "$remoteDir" > "$raw" 2>/dev/null || return 1
    awk '$4 > 0 && $NF ~ /nanoaod_[0-9]+\.root$/ {
           n = $NF ; sub(/.*nanoaod_/, "", n) ; sub(/\.root$/, "", n) ; print n + 0
         }' "$raw" | sort -n -u
  else
    [ -d "$remoteDir" ] || return 1
    find "$remoteDir" -maxdepth 1 -name 'nanoaod_*.root' -size +0c -printf '%f\n' 2>/dev/null \
      | sed 's/^nanoaod_//; s/\.root$//' | sort -n -u
  fi
  rm -f "$raw"
}

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

# 3b. with --resubmit, work out what is actually missing on EOS. njobs still
#     defines the index space (0..njobs-1) of the original submission, so it has
#     to be the same value it was submitted with.
declare -A JOBLIST NMISS NDONE
planned=$((NJOBS * nsamples))
if [ "$RESUBMIT" -eq 1 ]; then
  planned=0
  for s in $SAMPLES; do
    # a second cluster of the same sample would race the first one for the same
    # output files, so refuse unless the queue is clear of it
    queued=$(condor_q -af JobBatchName 2>/dev/null | grep -Fxc "run $BASE/$s")
    [[ "$queued" =~ ^[0-9]+$ ]] || queued=0
    if [ "$queued" -gt 0 ] && [ "$FORCE" -ne 1 ]; then
      fail "$queued job(s) of $s are still in the queue. Let them finish, or
       condor_rm them, or pass --force if you know they are stuck."
    fi

    done_indices "$BASE/$s" > "$tmpdir/$s.done" \
      || fail "cannot list $BASE/$s - is the proxy valid and the directory there?"
    jl=$baseDir/$s/condor/resubmit_$stamp.txt
    awk -v n="$NJOBS" 'BEGIN { while ((getline i < ARGV[1]) > 0) have[i+0] = 1
                               for (j = 0; j < n; j++) if (!(j in have)) print j }' \
        "$tmpdir/$s.done" > "$jl"
    NDONE[$s]=$(wc -l < "$tmpdir/$s.done")
    NMISS[$s]=$(wc -l < "$jl")
    JOBLIST[$s]=condor/resubmit_$stamp.txt
    [ "${NMISS[$s]}" -gt 0 ] || rm -f "$jl"
    planned=$((planned + NMISS[$s]))
  done
  [ "$planned" -gt 0 ] || { echo "  resubmit   : nothing missing, all samples complete" ; exit 0 ; }
  echo "  resubmit   : OK $planned job(s) missing across $nsamples sample(s)"
fi

# 4. room in the queue
maxjobs=$(condor_config_val -schedd MAX_JOBS_PER_OWNER 2>/dev/null)
[[ "$maxjobs" =~ ^[0-9]+$ ]] || maxjobs=100000
inqueue=$(condor_q -totals 2>/dev/null | awk -v u="$(whoami):" '$1=="Total" && $3==u {print $4; exit}')
[[ "$inqueue" =~ ^[0-9]+$ ]] || inqueue=0
if [ $((inqueue + planned)) -gt "$maxjobs" ]; then
  fail "$inqueue jobs already queued + $planned planned > MAX_JOBS_PER_OWNER ($maxjobs)"
fi
echo "  queue      : OK $inqueue queued + $planned planned <= $maxjobs"

# ---------------------------------------------------------------- summary ---
echo
if [ "$RESUBMIT" -eq 1 ]; then
  printf "%-36s %9s %8s %8s %12s  %s\n" SAMPLE EV/JOB DONE MISSING EVENTS DESTINATION
  for s in $SAMPLES; do
    printf "%-36s %9d %8d %8d %12d  %s\n" \
      "$s" "$NEVENTS" "${NDONE[$s]}" "${NMISS[$s]}" "$((NEVENTS * NMISS[$s]))" "$BASE/$s"
  done
else
  printf "%-36s %9s %8s %12s  %s\n" SAMPLE EV/JOB JOBS EVENTS DESTINATION
  for s in $SAMPLES; do
    printf "%-36s %9d %8d %12d  %s\n" "$s" "$NEVENTS" "$NJOBS" "$total" "$BASE/$s"
  done
fi
echo
echo "  threads/job    : $NTHREADS  (request_cpus = $NCPUS)"
echo "  full job logs  : $([ "$LOGSAMPLE" = none ] && echo "failures only" || echo "every job of $LOGSAMPLE (-> <outdir>/logs/), failures elsewhere")"
echo "  jdl            : $JDL"
echo "  wall-time limit: ${FLAVOUR:-tomorrow (jdl default)}"
echo "  total jobs     : $planned"
echo "  total events   : $((NEVENTS * planned))"
echo "  est. output    : ~$(( NEVENTS * planned * 187 / 10000000 )) GB   (18.7 kB/event measured)"
if [ "$NTHREADS" -ge 2 ]; then
  secperev=23 ; threadnote="2 threads"
else
  secperev=30 ; threadnote="1 thread"
fi
echo "  est. wall time : ~$(( NEVENTS * planned * secperev / 3600 )) job-hours ($secperev s/event measured, $threadnote)"
echo

# the flavour macro is only passed when asked for, so an unset --flavour keeps
# whatever the jdl itself says
flavourarg=""
[ -n "$FLAVOUR" ] && flavourarg="flavour=$FLAVOUR"

if [ "$DRYRUN" -eq 1 ]; then
  echo "=== dry run, submitting nothing ==="
  for s in $SAMPLES; do
    keeplog=0 ; [ "$s" = "$LOGSAMPLE" ] && keeplog=1
    if [ "$RESUBMIT" -eq 1 ]; then
      echo "(cd $baseDir/$s && condor_submit outdir=$BASE/$s joblist=${JOBLIST[$s]} nevents=$NEVENTS nthreads=$NTHREADS ncpus=$NCPUS keeplog=$keeplog $flavourarg $JDL)   # ${NMISS[$s]} job(s)"
    else
      echo "(cd $baseDir/$s && ./submit.sh $BASE/$s $JDL nevents=$NEVENTS njobs=$NJOBS nthreads=$NTHREADS ncpus=$NCPUS keeplog=$keeplog $flavourarg)"
    fi
  done
  [ "$RESUBMIT" -eq 1 ] && echo "job lists written to <sample>/condor/resubmit_$stamp.txt"
  exit 0
fi

if [ "$YES" -ne 1 ]; then
  read -r -p "Submit $planned jobs? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "aborted" ; exit 1 ;;
  esac
fi

# ------------------------------------------------------------- submission ---
record=$baseDir/$([ "$RESUBMIT" -eq 1 ] && echo resubmitted || echo submitted)_$stamp.txt
{
  echo "# submitted $(date -u +'%Y-%m-%d %H:%M:%S UTC') by $(whoami)"
  [ "$RESUBMIT" -eq 1 ] && echo "# retry of missing jobs, indices in <sample>/condor/resubmit_$stamp.txt"
  echo "# sample cluster njobs nevents nthreads ncpus outdir"
} > "$record"

nok=0
nbad=0
for s in $SAMPLES; do
  keeplog=0 ; [ "$s" = "$LOGSAMPLE" ] && keeplog=1
  echo "=== $s ==="
  if [ "$RESUBMIT" -eq 1 ]; then
    # straight to condor_submit: submit.sh deliberately refuses a non-empty
    # output directory, which is exactly the situation every retry is in
    njobs=${NMISS[$s]}
    out=$(cd "$baseDir/$s" && condor_submit outdir="$BASE/$s" joblist="${JOBLIST[$s]}" \
            nevents=$NEVENTS nthreads=$NTHREADS ncpus=$NCPUS keeplog=$keeplog \
            $flavourarg "$JDL" 2>&1)
  else
    njobs=$NJOBS
    out=$(cd "$baseDir/$s" && ./submit.sh "$BASE/$s" "$JDL" \
            nevents=$NEVENTS njobs=$NJOBS nthreads=$NTHREADS ncpus=$NCPUS keeplog=$keeplog \
            $flavourarg 2>&1)
  fi
  echo "$out"
  cluster=$(echo "$out" | sed -n 's/.*submitted to cluster \([0-9]*\).*/\1/p' | tail -1)
  if [ -n "$cluster" ]; then
    echo "$s $cluster $njobs $NEVENTS $NTHREADS $NCPUS $BASE/$s" >> "$record"
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
