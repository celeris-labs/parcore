# Select the correct ILA IP for the target architecture.
# NOTE: On Versal (e.g. V80) the IP is called axis_ila instead of ila,
#       and the versioned -version flag of the UltraScale+ ila core does not apply.
if {$cfg(fpga_arch) eq "ultrascale_plus"} {
    set ila_create_args [list -name ila -vendor xilinx.com -library ip -version 6.2]
} elseif {$cfg(fpga_arch) eq "versal"} {
    set ila_create_args [list -name axis_ila -vendor xilinx.com -library ip]
} else {
    puts "ERROR: Unsupported FPGA architecture: $cfg(fpga_arch)"
    exit 1
}

create_ip {*}$ila_create_args -module_name ila_run_decoder
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {40} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {3} \
    CONFIG.C_PROBE10_WIDTH {7} \
    CONFIG.C_PROBE11_WIDTH {7} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {32} \
    CONFIG.C_PROBE14_WIDTH {1} \
    CONFIG.C_PROBE15_WIDTH {28} \
    CONFIG.C_PROBE16_WIDTH {32} \
    CONFIG.C_PROBE17_WIDTH {32} \
    CONFIG.C_PROBE18_WIDTH {17} \
    CONFIG.C_PROBE19_WIDTH {4} \
    CONFIG.C_PROBE20_WIDTH {32} \
    CONFIG.C_PROBE21_WIDTH {1} \
    CONFIG.C_PROBE22_WIDTH {1} \
    CONFIG.C_PROBE23_WIDTH {1} \
    CONFIG.C_PROBE24_WIDTH {1} \
    CONFIG.C_PROBE25_WIDTH {1} \
    CONFIG.C_PROBE26_WIDTH {1} \
    CONFIG.C_PROBE27_WIDTH {1} \
    CONFIG.C_PROBE28_WIDTH {1} \
    CONFIG.C_PROBE29_WIDTH {1} \
    CONFIG.C_PROBE30_WIDTH {1} \
    CONFIG.C_PROBE31_WIDTH {1} \
    CONFIG.C_PROBE32_WIDTH {1} \
    CONFIG.C_PROBE33_WIDTH {1} \
    CONFIG.C_PROBE34_WIDTH {1} \
    CONFIG.C_PROBE35_WIDTH {1} \
    CONFIG.C_PROBE36_WIDTH {1} \
    CONFIG.C_PROBE37_WIDTH {1} \
    CONFIG.C_PROBE38_WIDTH {1} \
    CONFIG.C_PROBE39_WIDTH {32} \
] [get_ips ila_run_decoder]

# ColumnChunkDecoder handshakes: the ready/valid pair of every port of the five
# modules that can stall the pipeline on their own - Decompressor,
# HybridPageDecoder, Dictionary, PlainStringDecoder and the output multiplexer -
# plus the chunk FSM state (2) and the psd_out_heap counters (32 each). None of
# the widths depend on DATABEAT_SIZE, so this serves both the 32- and 64-byte
# configurations.
create_ip {*}$ila_create_args -module_name ila_cc_decoder
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {39} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {2} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {1} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {1} \
    CONFIG.C_PROBE14_WIDTH {1} \
    CONFIG.C_PROBE15_WIDTH {1} \
    CONFIG.C_PROBE16_WIDTH {1} \
    CONFIG.C_PROBE17_WIDTH {1} \
    CONFIG.C_PROBE18_WIDTH {1} \
    CONFIG.C_PROBE19_WIDTH {1} \
    CONFIG.C_PROBE20_WIDTH {1} \
    CONFIG.C_PROBE21_WIDTH {1} \
    CONFIG.C_PROBE22_WIDTH {1} \
    CONFIG.C_PROBE23_WIDTH {1} \
    CONFIG.C_PROBE24_WIDTH {1} \
    CONFIG.C_PROBE25_WIDTH {1} \
    CONFIG.C_PROBE26_WIDTH {1} \
    CONFIG.C_PROBE27_WIDTH {1} \
    CONFIG.C_PROBE28_WIDTH {1} \
    CONFIG.C_PROBE29_WIDTH {1} \
    CONFIG.C_PROBE30_WIDTH {1} \
    CONFIG.C_PROBE31_WIDTH {1} \
    CONFIG.C_PROBE32_WIDTH {1} \
    CONFIG.C_PROBE33_WIDTH {1} \
    CONFIG.C_PROBE34_WIDTH {1} \
    CONFIG.C_PROBE35_WIDTH {1} \
    CONFIG.C_PROBE36_WIDTH {32} \
    CONFIG.C_PROBE37_WIDTH {32} \
    CONFIG.C_PROBE38_WIDTH {32} \
] [get_ips ila_cc_decoder]

create_ip {*}$ila_create_args -module_name ila_hybrid_page_decoder
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {10} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {2} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {64} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {64} \
] [get_ips ila_hybrid_page_decoder]

create_ip {*}$ila_create_args -module_name ila_decompressor
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {18} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {1} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {64} \
    CONFIG.C_PROBE14_WIDTH {1} \
    CONFIG.C_PROBE15_WIDTH {1} \
    CONFIG.C_PROBE16_WIDTH {1} \
    CONFIG.C_PROBE17_WIDTH {64} \
] [get_ips ila_decompressor]

create_ip {*}$ila_create_args -module_name ila_top
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {9} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {64} \
    CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {64} \
] [get_ips ila_top]

# StreamWriterPairArbiter. Only instantiated for the 2-writer configuration, so
# the grant/head indices ($clog2(N_WRITERS)) and the per-writer vectors are 1 and
# 2 bits respectively.
create_ip {*}$ila_create_args -module_name ila_pair_arbiter
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {13} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {2} \
    CONFIG.C_PROBE2_WIDTH {3} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {2} \
    CONFIG.C_PROBE6_WIDTH {2} \
    CONFIG.C_PROBE7_WIDTH {2} \
    CONFIG.C_PROBE8_WIDTH {2} \
    CONFIG.C_PROBE9_WIDTH {2} \
    CONFIG.C_PROBE10_WIDTH {2} \
    CONFIG.C_PROBE11_WIDTH {2} \
    CONFIG.C_PROBE12_WIDTH {3} \
] [get_ips ila_pair_arbiter]

# PairedOutputWriter: both writers of one channel's (values, heap) pair plus the
# merged channel traffic. probe12 is req_t.len (LEN_BITS = 28), probe13 the low
# 32 bits of req_t.vaddr.
create_ip {*}$ila_create_args -module_name ila_paired_writer
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {16} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {2} \
    CONFIG.C_PROBE2_WIDTH {2} \
    CONFIG.C_PROBE3_WIDTH {3} \
    CONFIG.C_PROBE4_WIDTH {3} \
    CONFIG.C_PROBE5_WIDTH {2} \
    CONFIG.C_PROBE6_WIDTH {2} \
    CONFIG.C_PROBE7_WIDTH {2} \
    CONFIG.C_PROBE8_WIDTH {2} \
    CONFIG.C_PROBE9_WIDTH {3} \
    CONFIG.C_PROBE10_WIDTH {3} \
    CONFIG.C_PROBE11_WIDTH {2} \
    CONFIG.C_PROBE12_WIDTH {28} \
    CONFIG.C_PROBE13_WIDTH {32} \
    CONFIG.C_PROBE14_WIDTH {2} \
    CONFIG.C_PROBE15_WIDTH {3} \
] [get_ips ila_paired_writer]

# Per-decoder dataflow boundary in vfpga_top: input -> decoder -> values/heap ->
# writer. Every probe is a single handshake or last signal.
create_ip {*}$ila_create_args -module_name ila_cc_top
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {21} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {1} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {1} \
    CONFIG.C_PROBE14_WIDTH {1} \
    CONFIG.C_PROBE15_WIDTH {1} \
    CONFIG.C_PROBE16_WIDTH {1} \
    CONFIG.C_PROBE17_WIDTH {1} \
    CONFIG.C_PROBE18_WIDTH {1} \
    CONFIG.C_PROBE19_WIDTH {1} \
    CONFIG.C_PROBE20_WIDTH {1} \
] [get_ips ila_cc_top]

# Shell-facing writer traffic. Field widths come from lynxTypes: LEN_BITS 28,
# VADDR_BITS 48, DEST_BITS 4, PID_BITS 6, OPCODE_BITS 5, STRM_BITS 2, and the
# 32-bit irq_not_t value.
create_ip {*}$ila_create_args -module_name ila_shell_io
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {19} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {28} \
    CONFIG.C_PROBE4_WIDTH {48} \
    CONFIG.C_PROBE5_WIDTH {4} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {6} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {5} \
    CONFIG.C_PROBE11_WIDTH {2} \
    CONFIG.C_PROBE12_WIDTH {4} \
    CONFIG.C_PROBE13_WIDTH {6} \
    CONFIG.C_PROBE14_WIDTH {1} \
    CONFIG.C_PROBE15_WIDTH {1} \
    CONFIG.C_PROBE16_WIDTH {1} \
    CONFIG.C_PROBE17_WIDTH {6} \
    CONFIG.C_PROBE18_WIDTH {32} \
] [get_ips ila_shell_io]
