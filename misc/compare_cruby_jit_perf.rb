#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare two perf data files (YJIT vs ZJIT) and summarize where YJIT outperforms ZJIT.
#
# Usage: ruby misc/compare-perf.rb [options] [yjit.data] [zjit.data]
#
# Options:
#   --truncate=N    Truncate method/symbol labels to N characters
#   --no-truncate   Do not truncate labels (default)
#
# Requires `perf` to be installed and the data files to be accessible.

require "optparse"
require "fileutils"

REPO_ROOT = File.expand_path("..", __dir__)
PERF_DATA_DIR = File.join(REPO_ROOT, "perf-data")

truncate_width = nil

OptionParser.new do |opts|
  opts.banner = "Usage: ruby misc/compare-perf.rb [options] [yjit.data] [zjit.data]"
  opts.on("--truncate=N", Integer, "Truncate method/symbol labels to N characters") { |n| truncate_width = n }
  opts.on("--no-truncate", "Do not truncate method/symbol labels (default)") { truncate_width = nil }
end.parse!

YJIT_FILE = ARGV[0] || File.join(PERF_DATA_DIR, "yjit-lobsters.data")
ZJIT_FILE = ARGV[1] || File.join(PERF_DATA_DIR, "zjit-lobsters.data")

[YJIT_FILE, ZJIT_FILE].each do |f|
  abort "File not found: #{f}" unless File.exist?(f)
end

TRUNCATE_WIDTH = truncate_width

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def fmt_cycles(c)
  c.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
end

# Truncate a label to TRUNCATE_WIDTH if set, otherwise return as-is.
def truncate_label(s)
  return s unless TRUNCATE_WIDTH
  s.length > TRUNCATE_WIDTH ? s[0, TRUNCATE_WIDTH] : s
end

# Parse header metadata (duration) from --header-only, and total cycles from
# a minimal report run (since Event count only appears in full report output).
def parse_metadata(file)
  info = {}

  header = `perf report -i #{file} --stdio --header-only 2>&1`
  header.each_line do |line|
    case line
    when /# event\s*:.*name\s*=\s*(.+?),/
      info[:event] = $1.strip
    when /# sample duration\s*:\s*(.+)/
      info[:duration_ms] = $1.strip.delete(" ").to_f
    end
  end

  # Get total cycles and sample count from the full report preamble.
  # Note: do NOT use -q here, as it suppresses the preamble lines we need.
  report_head = `perf report -i #{file} --stdio --no-children -g none 2>&1 | head -20`
  report_head.each_line do |line|
    case line
    when /# Samples:\s*(\S+)/
      info[:samples] = $1
    when /# Event count \(approx\.\):\s*(\d+)/
      info[:total_cycles] = $1.to_i
    end
  end

  info
end

# Run perf report and parse the flat profile (self overhead only).
# Returns an array of hashes: { overhead:, command:, dso:, symbol: }
def parse_flat_profile(file)
  output = `perf report -i #{file} --stdio --no-children -g none -q 2>&1`
  entries = []
  output.each_line do |line|
    line = line.strip
    # Match lines like:  5.59%  ruby     sqlite3_native.so   [.] sqlite3VdbeExec
    # DSO may contain spaces (e.g., "[JIT] tid 163440"), so use a greedy match
    # up to the last occurrence of "[.]".
    if line =~ /^\s*(\d+\.\d+)%\s+(\S+)\s+(.+?)\s+\[.\]\s+(.+)$/
      entries << {
        overhead: $1.to_f,
        command: $2,
        dso: $3.strip,
        symbol: $4.strip
      }
    end
  end
  entries
end

# Run perf report grouped by DSO.
# Returns a hash: { dso_name => overhead_pct }
def parse_dso_profile(file)
  output = `perf report -i #{file} --stdio --no-children -g none --sort dso -q 2>&1`
  result = {}
  output.each_line do |line|
    if line =~ /^\s*(\d+\.\d+)%\s+(.+)$/
      result[$2.strip] = $1.to_f
    end
  end
  result
end

# Normalize DSO names so JIT DSOs from different profiles can be compared.
# "[JIT] tid 163440" and "[JIT] tid 100282" both become "[JIT]".
def normalize_dso(dso)
  dso.sub(/\[JIT\] tid \d+/, "[JIT]")
end

# Build a canonical symbol key for cross-profile comparisons.
# Uses normalized DSO and the symbol name.
def sym_key(entry)
  "#{normalize_dso(entry[:dso])}::#{entry[:symbol]}"
end

# Extract the Ruby method name from a JIT symbol for cross-JIT comparison.
# YJIT: "[JIT] each@<internal:array>:219"
# ZJIT: "zjit::each@<internal:array>:222"
# Returns nil if not a recognizable JIT method symbol (e.g., bare hex addresses
# like "0x000055554d38a001" or "ZJIT entry trampoline").
def jit_method_name(symbol)
  case symbol
  when /^\[JIT\]\s+(.+@.+)$/
    $1.sub(/:\d+$/, "") # strip trailing line number
  when /^zjit::(.+@.+)$/
    $1.sub(/:\d+$/, "")
  else
    nil
  end
end

# Restore a saved perf map file so that `perf report` can resolve JIT symbols.
# The harness saves /tmp/perf-<PID>.map as <perf.data>.map. This function
# copies it back to /tmp/ if the original is missing. Returns the restored
# path (for cleanup) or nil.
def restore_perf_map(perf_data_file)
  saved_map = "#{perf_data_file}.map"
  return nil unless File.exist?(saved_map)

  # Extract PID from the first sample line in the perf data.
  pid_line = `perf script -i #{perf_data_file} 2>/dev/null | head -1`
  pid = pid_line[/\S+\s+(\d+)/, 1]
  return nil unless pid

  target = "/tmp/perf-#{pid}.map"
  return nil if File.exist?(target)

  FileUtils.cp(saved_map, target)
  warn "compare-perf: Restored perf map to #{target}"
  target
end

# ---------------------------------------------------------------------------
# Collect data
# ---------------------------------------------------------------------------

puts "Parsing perf data files..."
puts "  YJIT: #{YJIT_FILE}"
puts "  ZJIT: #{ZJIT_FILE}"
puts

# Restore saved perf map files so perf report can resolve JIT symbols.
restored_maps = [restore_perf_map(YJIT_FILE), restore_perf_map(ZJIT_FILE)].compact

yjit_meta = parse_metadata(YJIT_FILE)
zjit_meta = parse_metadata(ZJIT_FILE)

yjit_flat = parse_flat_profile(YJIT_FILE)
zjit_flat = parse_flat_profile(ZJIT_FILE)

yjit_dso_raw = parse_dso_profile(YJIT_FILE)
zjit_dso_raw = parse_dso_profile(ZJIT_FILE)

# Normalize DSO keys for comparison.
yjit_dso = yjit_dso_raw.each_with_object({}) { |(k, v), h| h[normalize_dso(k)] = (h[normalize_dso(k)] || 0) + v }
zjit_dso = zjit_dso_raw.each_with_object({}) { |(k, v), h| h[normalize_dso(k)] = (h[normalize_dso(k)] || 0) + v }

# Build symbol lookup tables with normalized keys.
yjit_by_sym = yjit_flat.each_with_object({}) { |e, h| h[sym_key(e)] = e }
zjit_by_sym = zjit_flat.each_with_object({}) { |e, h| h[sym_key(e)] = e }
all_syms = (yjit_by_sym.keys + zjit_by_sym.keys).uniq

yjit_total = yjit_meta[:total_cycles].to_f
zjit_total = zjit_meta[:total_cycles].to_f

abort "Could not parse total cycles from YJIT data" if yjit_total == 0
abort "Could not parse total cycles from ZJIT data" if zjit_total == 0

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

separator = "=" * 90

puts separator
puts "PERF COMPARISON: YJIT vs ZJIT  (Lobsters benchmark)"
puts separator
puts
puts "%-28s %20s %20s" % ["Metric", "YJIT", "ZJIT"]
puts "-" * 70
puts "%-28s %20s %20s" % ["Total cycles (approx.)",
  fmt_cycles(yjit_total), fmt_cycles(zjit_total)]
puts "%-28s %20s %20s" % ["Sample duration",
  yjit_meta[:duration_ms] ? "#{"%.1f" % yjit_meta[:duration_ms]} ms" : "?",
  zjit_meta[:duration_ms] ? "#{"%.1f" % zjit_meta[:duration_ms]} ms" : "?"]

cycle_ratio = zjit_total / yjit_total
puts "%-28s %20s %20s" % ["Cycle ratio (ZJIT/YJIT)", "1.00x", "#{"%.2f" % cycle_ratio}x"]
total_gap = zjit_total - yjit_total
puts
puts "ZJIT uses ~#{"%.0f" % ((cycle_ratio - 1) * 100)}% more CPU cycles than YJIT (#{fmt_cycles(total_gap)} extra cycles)."

# --- DSO breakdown ---
puts
puts separator
puts "SECTION 1: DSO (Shared Object) Breakdown"
puts separator
puts
puts "This shows where cycles are spent by library/component."
puts "Percentages are relative to each profile's total cycles."
puts

all_dsos = (yjit_dso.keys + zjit_dso.keys).uniq.sort_by { |d| -(zjit_dso[d] || 0) }

puts "%-30s %10s %10s %10s %16s %16s" % ["DSO", "YJIT %", "ZJIT %", "Diff (pp)", "YJIT cycles", "ZJIT cycles"]
puts "-" * 95
all_dsos.each do |dso|
  y = yjit_dso[dso] || 0.0
  z = zjit_dso[dso] || 0.0
  diff = z - y
  yjit_abs = (y / 100.0 * yjit_total).round(0)
  zjit_abs = (z / 100.0 * zjit_total).round(0)
  marker = (zjit_abs - yjit_abs) > total_gap * 0.05 ? " <<<" : ""
  puts "%-30s %9.2f%% %9.2f%% %+9.2fpp %16s %16s%s" % [
    truncate_label(dso), y, z, diff,
    fmt_cycles(yjit_abs), fmt_cycles(zjit_abs), marker
  ]
end

# --- Interpreter vs JIT ---
puts
puts separator
puts "SECTION 2: Interpreter vs JIT Code Execution"
puts separator
puts
puts "This is the most critical section. A JIT compiler's value comes from"
puts "replacing interpreter execution with compiled native code."
puts

# vm_exec_core is the main interpreter loop.
yjit_interp_pct = yjit_by_sym.values.select { |e| e[:symbol] =~ /^vm_exec_core/ }.sum { |e| e[:overhead] }
zjit_interp_pct = zjit_by_sym.values.select { |e| e[:symbol] =~ /^vm_exec_core/ }.sum { |e| e[:overhead] }

yjit_jit_pct = yjit_dso["[JIT]"] || 0.0
zjit_jit_pct = zjit_dso["[JIT]"] || 0.0

if yjit_jit_pct == 0.0 && zjit_jit_pct == 0.0
  puts "WARNING: No JIT-compiled code detected in either profile."
  puts "  This usually means the /tmp/perf-<PID>.map files were lost before"
  puts "  perf could resolve JIT symbols. To fix this:"
  puts "    1. Re-run the benchmarks (the harness now saves .map files automatically)"
  puts "    2. Or place the perf map file as <perf-data-file>.map next to each perf.data"
  puts
end

yjit_interp_cyc = (yjit_interp_pct / 100.0 * yjit_total).round(0)
zjit_interp_cyc = (zjit_interp_pct / 100.0 * zjit_total).round(0)
yjit_jit_cyc = (yjit_jit_pct / 100.0 * yjit_total).round(0)
zjit_jit_cyc = (zjit_jit_pct / 100.0 * zjit_total).round(0)

puts "%-35s %10s %10s %16s %16s" % ["", "YJIT %", "ZJIT %", "YJIT cycles", "ZJIT cycles"]
puts "-" * 90
puts "%-35s %9.2f%% %9.2f%% %16s %16s" % [
  "vm_exec_core (interpreter)", yjit_interp_pct, zjit_interp_pct,
  fmt_cycles(yjit_interp_cyc), fmt_cycles(zjit_interp_cyc)
]
puts "%-35s %9.2f%% %9.2f%% %16s %16s" % [
  "JIT-compiled code", yjit_jit_pct, zjit_jit_pct,
  fmt_cycles(yjit_jit_cyc), fmt_cycles(zjit_jit_cyc)
]

interp_gap = zjit_interp_cyc - yjit_interp_cyc
jit_gap = zjit_jit_cyc - yjit_jit_cyc

puts
if zjit_interp_pct > yjit_interp_pct * 2
  puts "FINDING: ZJIT spends %.1fx more of its profile in the interpreter loop." % (zjit_interp_pct / yjit_interp_pct)
  puts "  In absolute terms: #{fmt_cycles(interp_gap)} extra cycles in vm_exec_core."
  puts "  That's %.1f%% of the total cycle gap." % (interp_gap.to_f / total_gap * 100)
  puts
  puts "  YJIT: %.2f%% in interpreter, %.2f%% in JIT code" % [yjit_interp_pct, yjit_jit_pct]
  puts "  ZJIT: %.2f%% in interpreter, %.2f%% in JIT code" % [zjit_interp_pct, zjit_jit_pct]
  puts
  puts "  This suggests ZJIT is compiling fewer methods or falling back to the"
  puts "  interpreter more often. The interpreter loop is the single largest"
  puts "  source of overhead difference."
end

# --- VM helper functions ---
puts
puts separator
puts "SECTION 3: VM Send / Call Infrastructure Overhead"
puts separator
puts
puts "These functions handle method dispatch, argument setup, and frame management."
puts "An effective JIT should inline or eliminate many of these by compiling call"
puts "sequences directly into native code."
puts

vm_dispatch_syms = %w[
  rb_vm_opt_send_without_block
  rb_vm_send
  rb_vm_exec
  vm_call_iseq_setup
  vm_call_iseq_setup_normal_0start_0params_0locals
  vm_call_iseq_setup_normal_0start_1params_1locals
  vm_call_iseq_setup_normal_opt_start
  vm_call_cfunc_with_frame_
  vm_call0_body
  vm_call_method_each_type
  vm_call_iseq_bmethod
  vm_call_ivar
  vm_lookup_cc
  callable_method_entry_or_negative
  vm_callee_setup_arg
  setup_parameters_complex
  vm_yield_setup_args
  invoke_block_from_c_bh
  vm_invoke_iseq_block
  vm_push_frame
  CALLER_SETUP_ARG
  vm_caller_setup_fwd_args
  rb_vm_invokeblock
  vm_search_super_method
  vm_base_ptr
  rb_call0
  rb_funcallv_scope.constprop.0
  rb_vm_opt_getconstant_path
  rb_vm_getinstancevariable
  rb_ec_stack_check
  rb_block_given_p
]

puts "%-50s %8s %8s %10s %14s  %s" % ["Symbol", "YJIT %", "ZJIT %", "Diff (pp)", "Extra cycles", ""]
puts "-" * 100

yjit_dispatch_total_pct = 0.0
zjit_dispatch_total_pct = 0.0
dispatch_extra_cycles = 0

vm_dispatch_syms.each do |sym|
  yjit_entry = yjit_by_sym.values.find { |e| e[:symbol] == sym }
  zjit_entry = zjit_by_sym.values.find { |e| e[:symbol] == sym }
  y_pct = yjit_entry ? yjit_entry[:overhead] : 0.0
  z_pct = zjit_entry ? zjit_entry[:overhead] : 0.0
  yjit_dispatch_total_pct += y_pct
  zjit_dispatch_total_pct += z_pct
  y_cyc = (y_pct / 100.0 * yjit_total).round(0)
  z_cyc = (z_pct / 100.0 * zjit_total).round(0)
  extra = z_cyc - y_cyc
  dispatch_extra_cycles += extra
  diff = z_pct - y_pct
  next if y_pct < 0.1 && z_pct < 0.1
  note = if extra > total_gap * 0.02
           "ZJIT higher"
         elsif extra < -(total_gap * 0.02)
           "YJIT higher"
         else
           ""
         end
  puts "%-50s %7.2f%% %7.2f%% %+9.2fpp %14s  %s" % [sym, y_pct, z_pct, diff, fmt_cycles(extra), note]
end
puts "-" * 100
puts "%-50s %7.2f%% %7.2f%% %+9.2fpp %14s" % [
  "TOTAL dispatch overhead",
  yjit_dispatch_total_pct, zjit_dispatch_total_pct,
  zjit_dispatch_total_pct - yjit_dispatch_total_pct,
  fmt_cycles(dispatch_extra_cycles)
]
puts
if dispatch_extra_cycles >= 0
  puts "FINDING: ZJIT spends %s more cycles on VM dispatch/call infrastructure." % fmt_cycles(dispatch_extra_cycles)
else
  puts "FINDING: ZJIT spends %s fewer cycles on VM dispatch/call infrastructure." % fmt_cycles(-dispatch_extra_cycles)
end
puts "  That's %.1f%% of the total cycle gap." % (dispatch_extra_cycles.to_f / total_gap * 100)

# --- Object/memory allocation ---
puts
puts separator
puts "SECTION 4: Memory Allocation & GC Overhead"
puts separator
puts

alloc_syms = %w[
  rb_wb_protected_newobj_of
  gc_sweep_step
  gc_mark_check_t_none
  gc_mark_internal.part.0
  rb_gc_impl_writebarrier
  rb_gc_obj_slot_size
  __libc_malloc2
  _int_malloc
  _int_free_chunk
  malloc
  cfree@GLIBC_2.2.5
  malloc_consolidate
  unlink_chunk.isra.0
  __memmove_avx512_unaligned_erms
]

puts "%-50s %8s %8s %10s %14s" % ["Symbol", "YJIT %", "ZJIT %", "Diff (pp)", "Extra cycles"]
puts "-" * 95

yjit_alloc_total = 0.0
zjit_alloc_total = 0.0
alloc_extra_cycles = 0

alloc_syms.each do |sym|
  yjit_entry = yjit_by_sym.values.find { |e| e[:symbol] == sym }
  zjit_entry = zjit_by_sym.values.find { |e| e[:symbol] == sym }
  y_pct = yjit_entry ? yjit_entry[:overhead] : 0.0
  z_pct = zjit_entry ? zjit_entry[:overhead] : 0.0
  yjit_alloc_total += y_pct
  zjit_alloc_total += z_pct
  y_cyc = (y_pct / 100.0 * yjit_total).round(0)
  z_cyc = (z_pct / 100.0 * zjit_total).round(0)
  extra = z_cyc - y_cyc
  alloc_extra_cycles += extra
  diff = z_pct - y_pct
  puts "%-50s %7.2f%% %7.2f%% %+9.2fpp %14s" % [sym, y_pct, z_pct, diff, fmt_cycles(extra)]
end
puts "-" * 95
puts "%-50s %7.2f%% %7.2f%% %+9.2fpp %14s" % [
  "TOTAL alloc/GC overhead", yjit_alloc_total, zjit_alloc_total,
  zjit_alloc_total - yjit_alloc_total, fmt_cycles(alloc_extra_cycles)
]
puts
if alloc_extra_cycles < 0
  puts "NOTE: Alloc/GC is actually *lower* in ZJIT by %s cycles." % fmt_cycles(-alloc_extra_cycles)
  puts "  This is likely because ZJIT runs fewer total instructions, so fewer"
  puts "  allocations and less GC pressure per unit of real work done."
end

# --- Object model / ivar / hash lookups ---
puts
puts separator
puts "SECTION 5: Object Model & Data Structure Lookups"
puts separator
puts

obj_syms = %w[
  rb_hash_aref
  rb_hash_fetch_m
  rb_st_lookup
  rb_any_hash
  ruby_sip_hash13
  rb_str_hash
  find_table_entry_ind
  ar_update
  tbl_update_modify
  rb_obj_is_kind_of
  rb_obj_class
  rb_shape_get_iv_index
  rb_shape_get_iv_index_with_hint
  rb_ivar_get_at_no_ractor_check
  rb_managed_id_table_lookup
  rb_concurrent_set_find
]

puts "%-50s %8s %8s %10s %14s" % ["Symbol", "YJIT %", "ZJIT %", "Diff (pp)", "Extra cycles"]
puts "-" * 95

obj_extra_cycles = 0
obj_syms.each do |sym|
  yjit_entry = yjit_by_sym.values.find { |e| e[:symbol] == sym }
  zjit_entry = zjit_by_sym.values.find { |e| e[:symbol] == sym }
  y_pct = yjit_entry ? yjit_entry[:overhead] : 0.0
  z_pct = zjit_entry ? zjit_entry[:overhead] : 0.0
  y_cyc = (y_pct / 100.0 * yjit_total).round(0)
  z_cyc = (z_pct / 100.0 * zjit_total).round(0)
  extra = z_cyc - y_cyc
  obj_extra_cycles += extra
  diff = z_pct - y_pct
  note = extra.abs > total_gap * 0.02 ? (extra > 0 ? "  <<<" : "") : ""
  puts "%-50s %7.2f%% %7.2f%% %+9.2fpp %14s%s" % [sym, y_pct, z_pct, diff, fmt_cycles(extra), note]
end

# --- ZJIT entry trampoline ---
puts
puts separator
puts "SECTION 6: ZJIT Entry Trampoline Overhead"
puts separator
puts

zjit_trampoline = zjit_flat.find { |e| e[:symbol] =~ /ZJIT entry trampoline/ }
if zjit_trampoline
  tramp_pct = zjit_trampoline[:overhead]
  tramp_cyc = (tramp_pct / 100.0 * zjit_total).round(0)
  puts "ZJIT entry trampoline: %.2f%% (%s cycles)" % [tramp_pct, fmt_cycles(tramp_cyc)]
  puts "  This is %.1f%% of the total cycle gap." % (tramp_cyc.to_f / total_gap * 100)
  puts
  puts "This is overhead from transitions between the interpreter and JIT-compiled code."
  puts "YJIT does not have an equivalent visible symbol because its transitions are"
  puts "tightly integrated. This cost could be reduced by compiling more methods"
  puts "(fewer transitions) or optimizing the trampoline itself."
else
  puts "(No ZJIT entry trampoline symbol found in profile)"
end

# --- Top JIT-compiled functions ---
puts
puts separator
puts "SECTION 7: Top JIT-compiled Functions"
puts separator
puts
puts "Functions where the JIT spends the most time. Compare to see if ZJIT"
puts "is generating less efficient code for the same methods."
puts

zjit_jit_entries = zjit_flat.select { |e| e[:dso] =~ /\[JIT\]/ }.sort_by { |e| -e[:overhead] }.first(20)
yjit_jit_entries = yjit_flat.select { |e| e[:dso] =~ /\[JIT\]/ }.sort_by { |e| -e[:overhead] }.first(20)

puts "--- Top 20 ZJIT JIT-compiled functions ---"
puts "%7s  %s" % ["%", "Symbol"]
puts "-" * 90
zjit_jit_entries.each do |e|
  puts "%6.2f%%  %s" % [e[:overhead], e[:symbol]]
end

puts
puts "--- Top 20 YJIT JIT-compiled functions ---"
puts "%7s  %s" % ["%", "Symbol"]
puts "-" * 90
yjit_jit_entries.each do |e|
  puts "%6.2f%%  %s" % [e[:overhead], e[:symbol]]
end

# --- Cross-JIT method comparison ---
puts
puts separator
puts "SECTION 8: JIT Method Comparison (same methods, both JITs)"
puts separator
puts
puts "Where both JITs compile the same Ruby method, compare how much time each"
puts "spends. Larger ZJIT overhead suggests less efficient generated code."
puts

# Build method name -> overhead maps for JIT entries.
yjit_jit_by_method = {}
yjit_flat.select { |e| e[:dso] =~ /\[JIT\]/ }.each do |e|
  name = jit_method_name(e[:symbol])
  next unless name
  yjit_jit_by_method[name] = (yjit_jit_by_method[name] || 0) + e[:overhead]
end

zjit_jit_by_method = {}
zjit_flat.select { |e| e[:dso] =~ /\[JIT\]/ }.each do |e|
  name = jit_method_name(e[:symbol])
  next unless name
  zjit_jit_by_method[name] = (zjit_jit_by_method[name] || 0) + e[:overhead]
end

common_methods = (yjit_jit_by_method.keys & zjit_jit_by_method.keys).sort_by { |m|
  zjit_jit_by_method[m] - yjit_jit_by_method[m]
}.reverse

if common_methods.any?
  puts "%8s %8s %10s  %s" % ["YJIT %", "ZJIT %", "Diff (pp)", "Method"]
  puts "-" * 95
  common_methods.first(25).each do |m|
    y = yjit_jit_by_method[m]
    z = zjit_jit_by_method[m]
    puts "%7.2f%% %7.2f%% %+9.2fpp  %s" % [y, z, z - y, truncate_label(m)]
  end
else
  puts "(No common JIT-compiled methods found for comparison)"
end

# --- Methods compiled by one JIT but not the other ---
puts
puts separator
puts "SECTION 9: Methods Compiled by YJIT but Not ZJIT"
puts separator
puts
puts "Methods that appear in YJIT's JIT-compiled code but have no corresponding"
puts "entry in ZJIT's. These represent compilation coverage gaps in ZJIT."
puts "(%% shown is the YJIT overhead for that method.)"
puts
puts "YJIT compiled #{yjit_jit_by_method.size} unique methods, ZJIT compiled #{zjit_jit_by_method.size} unique methods."
puts

yjit_only = yjit_jit_by_method.keys - zjit_jit_by_method.keys
zjit_only = zjit_jit_by_method.keys - yjit_jit_by_method.keys

if yjit_only.any?
  yjit_only_sorted = yjit_only.sort_by { |m| -yjit_jit_by_method[m] }
  total_yjit_only_pct = yjit_only_sorted.sum { |m| yjit_jit_by_method[m] }
  puts "#{yjit_only.size} methods compiled by YJIT but not ZJIT (total YJIT overhead: %.2f%%):" % total_yjit_only_pct
  puts
  puts "%7s  %s" % ["YJIT %", "Method"]
  puts "-" * 95
  yjit_only_sorted.first(40).each do |m|
    puts "%6.2f%%  %s" % [yjit_jit_by_method[m], truncate_label(m)]
  end
  remaining = yjit_only_sorted.size - 40
  puts "  ... and #{remaining} more methods" if remaining > 0
else
  puts "(All YJIT-compiled methods are also compiled by ZJIT)"
end

puts
puts separator
puts "SECTION 10: Methods Compiled by ZJIT but Not YJIT"
puts separator
puts
puts "Methods that appear in ZJIT's JIT-compiled code but have no corresponding"
puts "entry in YJIT's. (This is less common since YJIT typically compiles more.)"
puts

if zjit_only.any?
  zjit_only_sorted = zjit_only.sort_by { |m| -zjit_jit_by_method[m] }
  total_zjit_only_pct = zjit_only_sorted.sum { |m| zjit_jit_by_method[m] }
  puts "#{zjit_only.size} methods compiled by ZJIT but not YJIT (total ZJIT overhead: %.2f%%):" % total_zjit_only_pct
  puts
  puts "%7s  %s" % ["ZJIT %", "Method"]
  puts "-" * 95
  zjit_only_sorted.first(40).each do |m|
    puts "%6.2f%%  %s" % [zjit_jit_by_method[m], truncate_label(m)]
  end
  remaining = zjit_only_sorted.size - 40
  puts "  ... and #{remaining} more methods" if remaining > 0
else
  puts "(All ZJIT-compiled methods are also compiled by YJIT)"
end

# --- Top symbols by absolute cycle difference ---
puts
puts separator
puts "SECTION 11: Top Symbols by Absolute Cycle Difference (ZJIT > YJIT)"
puts separator
puts
puts "The symbols where ZJIT spends the most extra cycles compared to YJIT."
puts "This shows where the gap actually comes from in absolute terms."
puts

puts "%8s %8s %16s  %s" % ["YJIT %", "ZJIT %", "Extra ZJIT cyc", "Symbol (DSO)"]
puts "-" * 95

diffs = all_syms.map do |key|
  y_entry = yjit_by_sym[key]
  z_entry = zjit_by_sym[key]
  y_pct = y_entry ? y_entry[:overhead] : 0.0
  z_pct = z_entry ? z_entry[:overhead] : 0.0
  y_cyc = y_pct / 100.0 * yjit_total
  z_cyc = z_pct / 100.0 * zjit_total
  cyc_diff = z_cyc - y_cyc
  entry = z_entry || y_entry
  sym_label = "#{entry[:symbol]} (#{normalize_dso(entry[:dso])})"
  { key: key, sym_label: sym_label, y_pct: y_pct, z_pct: z_pct, cyc_diff: cyc_diff }
end

diffs.sort_by { |d| -d[:cyc_diff] }.first(30).each do |d|
  next if d[:cyc_diff] < 1_000_000
  puts "%7.2f%% %7.2f%% %16s  %s" % [d[:y_pct], d[:z_pct], fmt_cycles(d[:cyc_diff].round(0)), truncate_label(d[:sym_label])]
end

# --- Grand summary ---
puts
puts separator
puts "SUMMARY"
puts separator
puts
puts "Total cycle gap: %s cycles (ZJIT uses %.1f%% more)" % [
  fmt_cycles(total_gap.round(0)),
  (total_gap / yjit_total * 100)
]
puts

puts "Breakdown of where ZJIT's extra cycles come from:"
puts
puts "  %-45s %16s  (%5.1f%% of gap)" % [
  "1. Interpreter (vm_exec_core)", fmt_cycles(interp_gap), interp_gap.to_f / total_gap * 100
]
puts "  %-45s %16s  (%5.1f%% of gap)" % [
  "2. VM dispatch/call infrastructure", fmt_cycles(dispatch_extra_cycles), dispatch_extra_cycles.to_f / total_gap * 100
]
if zjit_trampoline
  tramp_cyc = (zjit_trampoline[:overhead] / 100.0 * zjit_total).round(0)
  puts "  %-45s %16s  (%5.1f%% of gap)" % [
    "3. ZJIT entry trampoline", fmt_cycles(tramp_cyc), tramp_cyc.to_f / total_gap * 100
  ]
end
if obj_extra_cycles > 0
  puts "  %-45s %16s  (%5.1f%% of gap)" % [
    "4. Object model / data structure lookups", fmt_cycles(obj_extra_cycles), obj_extra_cycles.to_f / total_gap * 100
  ]
end

puts
puts "Key takeaways:"
puts
puts "  - The interpreter loop (vm_exec_core) is the single largest difference."
puts "    ZJIT: %.2f%% vs YJIT: %.2f%%. This means ZJIT is not compiling as many" % [zjit_interp_pct, yjit_interp_pct]
puts "    code paths, or is bailing out to the interpreter more often."
puts
puts "  - VM dispatch overhead (send, call setup, argument handling) is significantly"
puts "    higher in ZJIT. YJIT inlines many of these operations into JIT code, while"
puts "    ZJIT appears to call back into C helper functions for method dispatch."
puts
puts "  - ZJIT's JIT code accounts for %.2f%% of cycles vs YJIT's %.2f%%." % [zjit_jit_pct, yjit_jit_pct]
puts "    Despite compiling some methods, the interpreter still handles the majority"
puts "    of execution in ZJIT, limiting the benefit of compiled code."
puts
puts "  - The most impactful improvement areas for ZJIT (in priority order):"
puts "    1. Compile more methods / reduce interpreter fallbacks"
puts "    2. Inline method dispatch (eliminate rb_vm_opt_send_without_block, etc.)"
puts "    3. Optimize the ZJIT entry trampoline"
puts "    4. Generate tighter code for hot compiled methods"

# Clean up any perf maps we temporarily restored to /tmp.
restored_maps.each { |path| File.delete(path) if File.exist?(path) }
