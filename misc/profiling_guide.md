# Profiling Guide for ZJIT (and YJIT)

This guide covers profiling Ruby benchmarks with `perf` and `callgrind`
to understand where compute time is being spent.

## Prerequisites

- Linux with `perf` installed
- `valgrind` installed (for callgrind)
- A Ruby build with ZJIT (or YJIT) support via chruby (e.g., `ruby-master`)
- Optional: [FlameGraph](https://github.com/brendangregg/FlameGraph) tools for flamegraph generation

## Quick Start (perf)

```bash
# 1. Ensure benchmark gems are installed (only needed once, or after Gemfile changes)
./run_benchmarks.rb --chruby 'ruby-master --zjit' --harness harness-once lobsters

# 2. Switch to the target Ruby
chruby ruby-master

# 3. Record a perf profile
PERF='record -g --call-graph dwarf' ruby --zjit -Iharness-perf benchmarks/lobsters/benchmark.rb

# 4. Analyze
ruby misc/analyze_perf.rb perf.data
```

## Perf Profiling (detailed)

### Step 1: Set up the benchmark

Benchmarks with dependencies (like lobsters, railsbench, etc.) need their
gems installed first. The easiest way is a one-shot run:

```bash
./run_benchmarks.rb --chruby 'ruby-master --zjit' --harness harness-once lobsters
```

Simple benchmarks without Gemfiles (e.g., `fib`, `lee`) can skip this step.

### Step 2: Record a profile

Switch to your target Ruby and run the benchmark directly with `harness-perf`:

```bash
chruby ruby-master
PERF='record -g --call-graph dwarf' ruby --zjit -Iharness-perf benchmarks/lobsters/benchmark.rb
```

**Important:** Run the benchmark directly with `ruby`, not through
`run_benchmarks.rb`. The `harness-perf` harness is a minimal profiling
harness that does not produce the JSON timing results that
`run_benchmarks.rb` expects.

The `harness-perf` harness will:
- Run 10 warmup iterations (configurable via `WARMUP_ITRS`)
- Attach `perf record` to the process
- Run benchmark iterations (configurable via `MIN_BENCH_ITRS`)
- Write `perf.data` to the repository root

#### Tuning the recording

Control iterations with environment variables:

```bash
# More iterations for better sampling (default: 10 warmup, benchmark-specific bench)
WARMUP_ITRS=15 MIN_BENCH_ITRS=20 PERF='record -g --call-graph dwarf' \
  ruby --zjit -Iharness-perf benchmarks/lobsters/benchmark.rb
```

Other useful `PERF` values:

```bash
# Default cycle counting (lightweight)
PERF='record -e cycles'

# With call graph via DWARF debug info (recommended, needs debug symbols)
PERF='record -g --call-graph dwarf'

# With call graph via frame pointers (faster, but Ruby may not have frame pointers)
PERF='record -g --call-graph fp'

# With call graph via Last Branch Record (Intel CPUs only)
PERF='record -g --call-graph lbr'

# Statistical counters only (no perf.data, prints summary)
PERF='stat'
```

### Step 3: Analyze the profile

#### Categorized summary (recommended)

```bash
ruby misc/analyze_perf.rb perf.data
```

This produces:
- **DSO breakdown**: Which shared objects (ruby binary, JIT code, libc, kernel) account for what percentage
- **Category breakdown**: Time grouped by CRuby subsystem (VM core, GC, String, Array, Hash, etc.)
- **Top functions**: The hottest functions by self time
- **JIT analysis**: How much time is in JIT-compiled code

Options:

```bash
# Show only top 10 functions
ruby misc/analyze_perf.rb --top 10 perf.data

# Show only category breakdown
ruby misc/analyze_perf.rb --categories-only perf.data

# Generate a flamegraph SVG (requires FlameGraph tools in PATH)
ruby misc/analyze_perf.rb --flamegraph perf.data

# Higher minimum threshold (only show functions >= 1% overhead)
ruby misc/analyze_perf.rb --percent-limit 1.0 perf.data
```

#### Interactive exploration

```bash
# Interactive TUI (navigate with arrow keys, Enter to drill into call chains)
perf report -i perf.data

# Text-based flat profile
perf report --stdio --no-children -n -i perf.data

# Text-based with inclusive time (children)
perf report --stdio -n -i perf.data
```

#### Flamegraph (manual)

If you have Brendan Gregg's [FlameGraph](https://github.com/brendangregg/FlameGraph)
tools in your PATH:

```bash
perf script -i perf.data | stackcollapse-perf.pl | flamegraph.pl > flamegraph.svg
```

Open `flamegraph.svg` in a browser for an interactive view.

### JIT code visibility

By default, JIT-compiled code appears as hex addresses in perf profiles.
For better symbol resolution:

- **YJIT**: Pass `--yjit-perf` to enable perf map generation
- **ZJIT**: Check if `--zjit-perf` is supported in your build

When perf maps are available, JIT code will show with meaningful
symbol names instead of raw addresses.

## Callgrind Profiling (detailed)

Callgrind provides exact instruction counts rather than statistical
sampling. It is much slower (20-50x overhead) but gives precise call
counts and a detailed call tree. Best used for targeted analysis after
perf has identified areas of interest.

### Step 1: Set up the benchmark

Same as for perf:

```bash
./run_benchmarks.rb --chruby 'ruby-master --zjit' --harness harness-once lobsters
```

### Step 2: Record a profile

```bash
chruby ruby-master
WARMUP_ITRS=2 MIN_BENCH_ITRS=2 valgrind --tool=callgrind \
  --instr-atstart=no --callgrind-out-file=callgrind.out \
  ~/.rubies/ruby-master/bin/ruby --zjit -Iharness-callgrind benchmarks/lobsters/benchmark.rb
```

**Important notes:**

- The `--instr-atstart=no` flag is required. The harness uses
  `callgrind_control` to enable instrumentation only for benchmark
  iterations. Warmup runs at near-native speed with no data collected.
- Use the full path to the Ruby binary (e.g.,
  `~/.rubies/ruby-master/bin/ruby`) rather than a shim (e.g., rbenv).
  Valgrind does not follow `exec` calls by default, so if `ruby` resolves
  to a wrapper script, only the wrapper is profiled and the output will
  be empty.

This produces a single output file (`callgrind.out`) containing only
benchmark iteration data — no warmup or compilation overhead.

**Use reduced iterations.** Each lobsters iteration takes about 1-2
seconds normally. Under callgrind, that becomes 30-100 seconds per
iteration. Two warmup and two benchmark iterations is usually sufficient.
The warmup phase runs at near-native speed since instrumentation is off.

### Step 3: Analyze

```bash
# Annotated flat profile
callgrind_annotate callgrind.out

# GUI explorer (if installed)
kcachegrind callgrind.out
```

#### Verifying warmup isolation

The output file should contain only benchmark data. You can confirm this
by checking that:

- The header says `part 1` and `Trigger: Program termination` (no prior
  dumps means no warmup data was included).
- The instruction count scales linearly with `MIN_BENCH_ITRS`. For
  example, doubling `MIN_BENCH_ITRS` should roughly double the
  `summary:` line — if warmup were included, the ratio would be less
  than 2x due to the fixed startup overhead.

```bash
grep -E '^(desc: Trigger|summary)' callgrind.out
```

`kcachegrind` is particularly useful for callgrind data as it
visualizes the call tree, showing both self and inclusive costs.

## Tips

### CPU configuration for consistent results

When using `run_benchmarks.rb`, CPU boost and frequency scaling are
configured automatically. For direct runs, you may want to disable
boost manually:

```bash
# AMD
echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost

# Intel
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
```

### CPU pinning

For direct runs, you can pin to a specific core to reduce variance:

```bash
# Pin to core 7 and disable ASLR
setarch x86_64 -R taskset -c 7 ruby --zjit -Iharness-perf benchmarks/lobsters/benchmark.rb
```

### Comparing interpreter vs JIT

Profile the same benchmark without the JIT flag to see the difference:

```bash
# Interpreter only
PERF='record -g --call-graph dwarf' ruby -Iharness-perf benchmarks/lobsters/benchmark.rb

# With ZJIT
PERF='record -g --call-graph dwarf' ruby --zjit -Iharness-perf benchmarks/lobsters/benchmark.rb

# Analyze both
ruby misc/analyze_perf.rb perf.data
```

Rename `perf.data` between runs to keep both profiles.

### Simple benchmarks

For benchmarks without Gemfiles, no setup step is needed:

```bash
chruby ruby-master
PERF='record -g --call-graph dwarf' ruby --zjit -Iharness-perf benchmarks/fib.rb
ruby misc/analyze_perf.rb perf.data
```
