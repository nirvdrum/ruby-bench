#!/usr/bin/env ruby
# frozen_string_literal: true

# Analyze a perf.data file and produce a categorized summary of where
# compute time is being spent. Designed for profiling CRuby with JIT
# compilers (YJIT/ZJIT) on yjit-bench benchmarks.
#
# Usage:
#   ruby misc/analyze_perf.rb [options] [perf.data]
#   ruby misc/analyze_perf.rb --flamegraph perf.data
#
# See --help for all options.

require 'optparse'
require 'open3'
require 'fileutils'

class PerfAnalyzer
  PerfEntry = Struct.new(:overhead_pct, :samples, :command, :dso, :symbol_type, :symbol_name, :category, keyword_init: true)

  # Ordered by specificity — first match wins.
  FUNCTION_CATEGORIES = [
    { name: 'CRuby VM core',        pattern: /^(rb_vm_|vm_exec|vm_call|rb_call|rb_funcall|rb_yield|vm_push_frame|vm_pop_frame|rb_ec_|vm_invoke|invoke_|vm_sendish)/ },
    { name: 'CRuby GC',             pattern: /^(gc_|rb_gc_|newobj_|obj_free|objspace|rb_objspace|gc_mark)/ },
    { name: 'CRuby String',         pattern: /^(rb_str_|str_|rb_enc_str_|rb_usascii_str)/ },
    { name: 'CRuby Array',          pattern: /^(rb_ary_|ary_)/ },
    { name: 'CRuby Hash',           pattern: /^(rb_hash_|st_|hash_aref|hash_aset)/ },
    { name: 'CRuby Object/Class',   pattern: /^(rb_obj_|rb_ivar_|rb_class_|rb_mod_|rb_define_|rb_respond_to)/ },
    { name: 'CRuby Numeric',        pattern: /^(rb_int_|rb_fix|rb_float_|rb_num_|rb_integer_|rb_big_|rb_to_int|rb_to_float|int_|fix_)/ },
    { name: 'CRuby Regexp',         pattern: /^(rb_reg_|onig_|match_)/ },
    { name: 'CRuby Method dispatch', pattern: /^(rb_method_|rb_callable_|method_)/ },
    { name: 'CRuby Parse/Compile',  pattern: /^(rb_iseq_|iseq_|compile|rb_parser_)/ },
    { name: 'CRuby Encoding',       pattern: /^(rb_enc_|enc_|rb_must_asciicompat)/ },
    { name: 'CRuby IO',             pattern: /^(rb_io_|io_|rb_write)/ },
    { name: 'CRuby Pack',           pattern: /^(pack_)/ },
  ].freeze

  # Categories that represent Ruby core library methods (as opposed to runtime
  # infrastructure like VM core, GC, method dispatch, parse/compile).
  CORE_LIBRARY_CATEGORIES = [
    'CRuby String', 'CRuby Array', 'CRuby Hash', 'CRuby Object/Class',
    'CRuby Numeric', 'CRuby Regexp', 'CRuby Encoding', 'CRuby IO', 'CRuby Pack',
  ].freeze

  # Match perf report lines:
  #     26.22%         10314  ruby     ruby                  [.] rb_yjit_str_concat_codepoint
  # DSO can contain spaces (e.g., "[JIT] tid 224893"), so we anchor on the [.] or [k] marker.
  LINE_RE = /^\s*(\d+\.\d+)%\s+(\d+)\s+(\S+)\s+(.+?)\s+\[([.k])\]\s+(.+)$/

  def initialize(perf_data_path, options = {})
    @perf_data_path = perf_data_path
    @options = options
  end

  def analyze
    check_prerequisites
    @restored_perf_map = restore_perf_map

    entries = parse_perf_report
    if entries.empty?
      $stderr.puts "No samples found in #{@perf_data_path}."
      exit 1
    end

    print_header
    print_dso_breakdown
    puts
    print_category_breakdown(entries)
    puts
    print_core_method_breakdown(entries) unless @options[:categories_only]
    puts
    print_top_functions(entries) unless @options[:categories_only]
    puts
    print_jit_analysis(entries)

    generate_flamegraph if @options[:flamegraph]
  ensure
    if @restored_perf_map && File.exist?(@restored_perf_map)
      File.delete(@restored_perf_map)
    end
  end

  private

  def check_prerequisites
    unless system('which', 'perf', out: File::NULL, err: File::NULL)
      $stderr.puts "Error: 'perf' is not installed or not in PATH."
      exit 1
    end

    unless File.exist?(@perf_data_path)
      $stderr.puts "Error: #{@perf_data_path} not found."
      $stderr.puts
      $stderr.puts "Generate one with:"
      $stderr.puts "  PERF='record -g --call-graph dwarf' PERF_OUTPUT=perf-data/zjit-lobsters.data \\"
      $stderr.puts "    ./run_benchmarks.rb -e '/path/to/ruby --zjit --zjit-perf' \\"
      $stderr.puts "    --harness harness-perf --warmup 10 --bench 10 lobsters"
      exit 1
    end
  end

  # Restore a saved perf map file so that `perf report` can resolve JIT symbols.
  # Returns the restored path (for cleanup) or nil.
  def restore_perf_map
    saved_map = "#{@perf_data_path}.map"
    return nil unless File.exist?(saved_map)

    pid_line = `perf script -i #{@perf_data_path} 2>/dev/null | head -1`
    pid = pid_line[/\S+\s+(\d+)/, 1]
    return nil unless pid

    target = "/tmp/perf-#{pid}.map"
    return nil if File.exist?(target)

    FileUtils.cp(saved_map, target)
    $stderr.puts "analyze_perf: Restored perf map to #{target}"
    target
  end

  def parse_perf_report
    cmd = ['perf', 'report', '--stdio', '--no-children', '-n', '-g', 'none',
           '-i', @perf_data_path]
    output, status = Open3.capture2e(*cmd)
    unless status.success?
      $stderr.puts "perf report failed:"
      $stderr.puts output
      exit 1
    end

    entries = []
    output.each_line do |line|
      next if line.start_with?('#') || line.strip.empty?
      m = LINE_RE.match(line)
      next unless m

      entry = PerfEntry.new(
        overhead_pct: m[1].to_f,
        samples: m[2].to_i,
        command: m[3],
        dso: m[4].strip,
        symbol_type: m[5],
        symbol_name: m[6].strip,
        category: nil
      )
      entry.category = categorize(entry)
      entries << entry
    end

    entries.sort_by { |e| -e.overhead_pct }
  end

  def categorize(entry)
    dso = entry.dso
    sym = entry.symbol_name

    # JIT compiled code: [JIT] DSO or [unknown] with hex symbol
    if dso.start_with?('[JIT]')
      return 'JIT compiled code'
    end
    if dso == '[unknown]' && sym.match?(/^0x[0-9a-f]+$/)
      return 'JIT compiled code'
    end

    # Kernel
    return 'Kernel' if dso == '[kernel.kallsyms]' || dso.start_with?('[')

    # System libraries
    return 'libc/system libraries' if dso.match?(/^lib[cm][\.-]|^ld-linux|^libpthread|^libdl|^librt/)

    # CRuby categories (by symbol name pattern)
    FUNCTION_CATEGORIES.each do |cat|
      return cat[:name] if sym.match?(cat[:pattern])
    end

    # CRuby functions that don't match specific categories but are from the ruby binary
    return 'CRuby Other' if dso == 'ruby'

    'Other'
  end

  def print_header
    # Extract header info from perf data
    header_output, = Open3.capture2e('perf', 'report', '--stdio', '--header-only', '-i', @perf_data_path)

    captured_on = header_output[/^# captured on\s*:\s*(.+)/, 1] || 'unknown'
    cmdline = header_output[/^# cmdline\s*:\s*(.+)/, 1] || 'unknown'
    event_name = header_output[/^# event\s*:\s*name = (\S+)/, 1] || 'unknown'

    puts "=" * 70
    puts "Perf Profile Analysis"
    puts "=" * 70
    puts "Data file:    #{@perf_data_path}"
    puts "Captured on:  #{captured_on}"
    puts "Event:        #{event_name}"
    puts "Command:      #{cmdline}"
    puts "=" * 70
  end

  def print_dso_breakdown
    cmd = ['perf', 'report', '--stdio', '--no-children', '-n', '-g', 'none',
           '--sort=dso', '-i', @perf_data_path]
    output, = Open3.capture2e(*cmd)

    puts
    puts "--- Shared Object (DSO) Breakdown ---"
    puts "%10s  %10s  %-30s" % ["Overhead", "Samples", "Shared Object"]
    puts "-" * 55

    output.each_line do |line|
      next if line.start_with?('#') || line.strip.empty?
      if m = line.match(/^\s*(\d+\.\d+)%\s+(\d+)\s+(.+)$/)
        pct, samples, dso = m[1], m[2], m[3].strip
        puts "%9s%%  %10s  %-30s" % [pct, samples, dso]
      end
    end
  end

  def print_category_breakdown(entries)
    categories = Hash.new(0.0)
    entries.each do |entry|
      categories[entry.category] += entry.overhead_pct
    end

    sorted = categories.sort_by { |_, pct| -pct }
    total = sorted.sum { |_, pct| pct }

    puts "--- Category Breakdown ---"
    puts "%10s  %10s  %-30s" % ["Self%", "Cumulative", "Category"]
    puts "-" * 55

    cumulative = 0.0
    sorted.each do |cat, pct|
      cumulative += pct
      puts "%9.2f%%  %9.2f%%  %-30s" % [pct, cumulative, cat]
    end

    puts "-" * 55
    puts "%9.2f%%  %10s  Total" % [total, ""]
  end

  def print_core_method_breakdown(entries)
    limit = @options[:percent_limit]
    core_top = @options[:core_top]

    # Group entries by core library category
    by_category = Hash.new { |h, k| h[k] = [] }
    entries.each do |entry|
      next unless CORE_LIBRARY_CATEGORIES.include?(entry.category)
      by_category[entry.category] << entry
    end

    puts "--- Core Library Method Breakdown ---"

    any_printed = false
    CORE_LIBRARY_CATEGORIES.each do |cat_name|
      funcs = by_category[cat_name]
      next if funcs.nil? || funcs.empty?

      total_pct = funcs.sum(&:overhead_pct)
      next if total_pct < limit

      any_printed = true
      puts "  %-25s (total: %.2f%%)" % [cat_name, total_pct]
      puts "    %-10s  %10s  %s" % ["Self%", "Samples", "Function"]
      puts "  " + "-" * 70

      visible = funcs.first(core_top)
      visible.each do |entry|
        puts "    %6.2f%%  %10d  %s" % [entry.overhead_pct, entry.samples, entry.symbol_name]
      end

      remaining = funcs[core_top..]
      if remaining && !remaining.empty?
        remaining_pct = remaining.sum(&:overhead_pct)
        puts "    %6.2f%%  %10s  ... and %d more functions" % [remaining_pct, "", remaining.size]
      end
      puts
    end

    puts "  (no core library functions above threshold)" unless any_printed
  end

  def print_top_functions(entries)
    top_n = @options[:top]
    limit = @options[:percent_limit]

    visible = entries.select { |e| e.overhead_pct >= limit }.first(top_n)

    puts "--- Top #{visible.size} Functions (Self Time) ---"
    puts "%10s  %10s  %-25s  %s" % ["Self%", "Samples", "Category", "Function"]
    puts "-" * 85

    visible.each do |entry|
      puts "%9.2f%%  %10d  %-25s  %s" % [
        entry.overhead_pct,
        entry.samples,
        entry.category,
        entry.symbol_name
      ]
    end
  end

  def print_jit_analysis(entries)
    jit_entries = entries.select { |e| e.category == 'JIT compiled code' }
    jit_total = jit_entries.sum(&:overhead_pct)
    jit_samples = jit_entries.sum(&:samples)

    puts "--- JIT Code Analysis ---"

    if jit_entries.empty?
      puts "No JIT-compiled code detected in this profile."
      puts "If running with --zjit or --yjit, this usually means the"
      puts "/tmp/perf-<PID>.map file was lost before perf could resolve JIT symbols."
      puts
      puts "To fix this:"
      puts "  1. Re-run the benchmark (the harness now saves .map files automatically)"
      puts "  2. Or place the perf map file as <perf-data-file>.map next to the perf.data"
      puts "  3. Make sure to pass --yjit-perf or --zjit-perf to enable perf map generation"
      return
    end

    puts "Total JIT overhead: %.2f%% (%d samples across %d unique addresses)" % [
      jit_total, jit_samples, jit_entries.size
    ]

    # Check if symbols are resolved (named) vs hex addresses
    named = jit_entries.count { |e| !e.symbol_name.match?(/^0x[0-9a-f]+$/) }
    hex_only = jit_entries.size - named

    if hex_only > 0 && named == 0
      puts
      puts "All JIT symbols are unresolved hex addresses."
      puts "For better JIT symbol resolution, try:"
      puts "  --yjit-perf  (for YJIT perf map support)"
      puts "  --zjit-perf  (for ZJIT, if supported)"
    elsif named > 0
      puts "#{named} of #{jit_entries.size} JIT symbols are resolved."
    end

    # Show top JIT entries
    top_jit = jit_entries.first(10)
    unless top_jit.empty?
      puts
      puts "Top JIT code addresses:"
      top_jit.each do |entry|
        puts "  %6.2f%%  %6d samples  %s" % [entry.overhead_pct, entry.samples, entry.symbol_name]
      end
    end
  end

  def generate_flamegraph
    flamegraph_path = @options[:flamegraph]
    flamegraph_path = "flamegraph.svg" if flamegraph_path == true

    # Try Brendan Gregg's flamegraph tools
    stackcollapse = find_tool('stackcollapse-perf.pl')
    flamegraph_pl = find_tool('flamegraph.pl')

    if stackcollapse && flamegraph_pl
      puts
      puts "--- Generating Flamegraph ---"
      cmd = "perf script -i #{@perf_data_path} | #{stackcollapse} | #{flamegraph_pl} > #{flamegraph_path}"
      if system(cmd)
        puts "Flamegraph written to: #{flamegraph_path}"
        puts "Open in a browser to explore interactively."
      else
        $stderr.puts "Flamegraph generation failed."
      end
      return
    end

    # Try inferno (Rust-based flamegraph tool)
    inferno = find_tool('inferno-flamegraph')
    if inferno
      puts
      puts "--- Generating Flamegraph ---"
      cmd = "perf script -i #{@perf_data_path} | inferno-collapse-perf | inferno-flamegraph > #{flamegraph_path}"
      if system(cmd)
        puts "Flamegraph written to: #{flamegraph_path}"
      else
        $stderr.puts "Flamegraph generation failed."
      end
      return
    end

    puts
    puts "--- Flamegraph ---"
    puts "No flamegraph tools found. Install one of:"
    puts "  - Brendan Gregg's FlameGraph: https://github.com/brendangregg/FlameGraph"
    puts "    git clone https://github.com/brendangregg/FlameGraph"
    puts "    Then add FlameGraph/ to your PATH."
    puts "  - inferno (Rust): cargo install inferno"
  end

  def find_tool(name)
    path, status = Open3.capture2('which', name)
    status.success? ? path.strip : nil
  end
end

# --- CLI ---

options = { top: 30, percent_limit: 0.05, core_top: 10 }

parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options] [perf.data]"
  opts.separator ""
  opts.separator "Analyze a perf.data file and produce a categorized summary."
  opts.separator ""

  opts.on("-t", "--top N", Integer, "Show top N functions (default: #{options[:top]})") do |v|
    options[:top] = v
  end

  opts.on("-p", "--percent-limit PCT", Float, "Minimum overhead% to include (default: #{options[:percent_limit]})") do |v|
    options[:percent_limit] = v
  end

  opts.on("--core-top N", Integer, "Functions per core library category (default: #{options[:core_top]})") do |v|
    options[:core_top] = v
  end

  opts.on("--flamegraph [FILE]", "Generate flamegraph SVG (default: flamegraph.svg)") do |v|
    options[:flamegraph] = v || true
  end

  opts.on("--categories-only", "Show only category breakdown, skip per-function details") do
    options[:categories_only] = true
  end

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end

parser.parse!

perf_data_path = ARGV[0] || File.expand_path('../perf.data', __dir__)

PerfAnalyzer.new(perf_data_path, options).analyze
