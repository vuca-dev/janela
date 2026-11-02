#!/bin/zsh
# Reproduces the "Resource use" figures in README.md: scripts/benchmark.sh [minutes]
#
# Uses no camera and no footage. It draws a clip, replays it through a test build at 30 fps, and
# a reader on the virtual camera starts the app the way a meeting app does. Needs OBS's camera
# extension turned on (see README) and Janela quit. Each phase runs for [minutes], default 5.
set -e
cd "$(dirname "$0")/.."
minutes=${1:-5}
seconds=$(awk "BEGIN { printf \"%d\", $minutes * 60 }")
camera="OBS Virtual Camera"
work=$PWD/build.noindex/bench
mkdir -p "$work"
probe=.build/release/camera-probe

swift build -c release --product camera-probe 2>&1 | tail -1
if pgrep -x Janela > /dev/null; then echo "Quit Janela first: it holds the virtual camera."; exit 1; fi
if [ "$($probe running "$camera")" = "missing" ]; then echo "$camera isn't set up. Finish Janela's setup first."; exit 1; fi

if [ -z "$BENCH_APP" ]; then   # BENCH_APP measures an existing test build instead
  ./build_app.sh > /dev/null 2>&1
  app_size=$(du -sm build.noindex/Janela.app | cut -f1)
  JANELA_TEST=1 ./build_app.sh > /dev/null 2>&1
  rm -rf "$work/Janela.app"; mv build.noindex/Janela.app "$work/Janela.app"
  BENCH_APP=$work/Janela.app
else
  swift build -c release --product janela-render 2>&1 | tail -1
  app_size=$(du -sm "$BENCH_APP" | cut -f1)
fi
clip=$work/clip.mov
.build/release/janela-render synth "$clip" 60 > /dev/null

# A private home, so the run can't read or change anyone's location, scene or camera choices.
home=$work/home
mkdir -p "$home/Library/Application Support/Janela"
echo '{"scene":"atelier","enabled":true,"setupDone":true,"manualWeather":"clear","manualPhase":"noon"}' > "$home/Library/Application Support/Janela/config.json"

cpu_seconds() { ps -o time= -p "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'; }
footprint_mb() {
  footprint "$1" 2>/dev/null | sed -nE 's/.*Footprint: ([0-9.]+) (MB|GB|KB).*/\1 \2/p' | head -1 |
    awk '{ print ($2 == "GB" ? $1 * 1024 : $2 == "KB" ? $1 / 1024 : $1) }'
}
matted_frames() { awk -F'[ =]' '{ n += $6 } END { print n + 0 }' "$stats"; }
percent() { awk "BEGIN { printf \"%.1f\", ($2 - $1) * 100 / $3 }"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

stats=$work/stats
reader=""
cleanup() { [ -n "$reader" ] && kill "$reader" 2>/dev/null; [ -n "$pid" ] && kill "$pid" 2>/dev/null; true; }
trap cleanup EXIT

CFFIXED_USER_HOME=$home "$BENCH_APP/Contents/MacOS/Janela" -file "$clip" -stats "$stats" &
pid=$!

echo "Idle for $seconds s..."
sleep 30
c0=$(cpu_seconds $pid); t0=$(now)
sleep "$seconds"
c1=$(cpu_seconds $pid); t1=$(now)
idle_cpu=$(percent $c0 $c1 $(awk "BEGIN { print $t1 - $t0 }"))
idle_mem=$(footprint_mb $pid)

echo "Live for $seconds s..."
$probe read "$camera" --seconds $(( seconds + 120 )) > "$work/reader.log" 2>&1 &
reader=$!
t_reader=$(now)
until grep -q 'run=1' "$stats" 2>/dev/null; do sleep 0.1; done
until tail -1 "$stats" | grep -Eq 'fps=[1-9]'; do sleep 0.1; done
ready=$(awk "BEGIN { printf \"%.1f\", $(now) - $t_reader }")
sleep 30
frames0=$(matted_frames)
log0=$(wc -l < "$stats.frames" 2>/dev/null || echo 0)
c0=$(cpu_seconds $pid); t0=$(now); peak=0; sum=0; count=0
end=$(( SECONDS + seconds ))
while (( SECONDS < end )); do
  sleep 10
  m=$(footprint_mb $pid); sum=$(awk "BEGIN { print $sum + $m }"); count=$(( count + 1 ))
  peak=$(awk "BEGIN { print ($m > $peak) ? $m : $peak }")
done
c1=$(cpu_seconds $pid); t1=$(now)
elapsed=$(awk "BEGIN { print $t1 - $t0 }")
live_cpu=$(percent $c0 $c1 $elapsed)
fps=$(awk "BEGIN { printf \"%.1f\", ($(matted_frames) - $frames0) / $elapsed }")
sleep 1
if [ -s "$stats.frames" ]; then
  tail -n +$(( log0 + 1 )) "$stats.frames" | awk '{ print $2 }' | sort -n > "$work/total.txt"
  tail -n +$(( log0 + 1 )) "$stats.frames" | awk '{ print $1 }' | sort -n > "$work/matte.txt"
  at() { awk -v p="$2" 'NR == FNR { n++; next } FNR == int(n * p) + 1 { print; exit }' "$1" "$1"; }
  frame_ms="total p50 $(at $work/total.txt 0.50) ms, p95 $(at $work/total.txt 0.95) ms, p99 $(at $work/total.txt 0.99) ms over $(wc -l < $work/total.txt | tr -d ' ') frames"
  matte_ms="downscale + inference p50 $(at $work/matte.txt 0.50) ms, p95 $(at $work/matte.txt 0.95) ms"
else
  frame_ms="not recorded by this build"; matte_ms=""
fi
kill "$reader" 2>/dev/null || true; reader=""
for i in $(seq 1 1400); do tail -1 "$stats" | grep -q 'run=0' && break; sleep 0.1; done
after_mem=$(footprint_mb $pid)
kill "$pid" 2>/dev/null || true; pid=""
sleep 1

echo "Replay decode alone..."
control=$(( seconds < 60 ? seconds : 60 ))
.build/release/janela-render decode "$clip" "$control" &
d=$!
sleep 3
c0=$(cpu_seconds $d); t0=$(now)
sleep $(( control - 5 ))
c1=$(cpu_seconds $d); t1=$(now)
decode_cpu=$(percent $c0 $c1 $(awk "BEGIN { print $t1 - $t0 }"))
wait $d 2>/dev/null || true

cat <<R | tee "$work/result.txt"

Janela $(git rev-parse --short HEAD)$(git diff --quiet HEAD || echo ' (uncommitted changes)'), $(date +%F)
$(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))
Measured, Janela's process only, $minutes min per phase, drawn 1080p H.264 clip replayed at 30 fps:
  App size:             $app_size MB
  Idle, before use:     $idle_cpu% of one core, $idle_mem MB footprint
  Live:                 $live_cpu% of one core, $(awk "BEGIN { printf \"%.0f\", $sum / $count }") MB average footprint, $(printf %.0f $peak) MB peak
  Frame rate:           $fps fps
  Frame time:           $frame_ms
                        $matte_ms
  First matte frame:    about $ready s after a reader arrived
  After the reader left: $after_mem MB footprint
  Replay decode alone:  $decode_cpu% of one core, included in Live
Not measured: live-camera capture, Neural Engine and GPU load, energy, and other processes.
R
