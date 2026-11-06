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

create_ip {*}$ila_create_args -module_name ila_page_decoder
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {30} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {2} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {2} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {1} \
    CONFIG.C_PROBE11_WIDTH {32} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {1} \
    CONFIG.C_PROBE14_WIDTH {1} \
    CONFIG.C_PROBE15_WIDTH {64} \
    CONFIG.C_PROBE16_WIDTH {1} \
    CONFIG.C_PROBE17_WIDTH {1} \
    CONFIG.C_PROBE18_WIDTH {1} \
    CONFIG.C_PROBE19_WIDTH {64} \
    CONFIG.C_PROBE20_WIDTH {1} \
    CONFIG.C_PROBE21_WIDTH {1} \
    CONFIG.C_PROBE22_WIDTH {1} \
    CONFIG.C_PROBE23_WIDTH {1} \
    CONFIG.C_PROBE24_WIDTH {64} \
    CONFIG.C_PROBE25_WIDTH {1} \
    CONFIG.C_PROBE26_WIDTH {1} \
    CONFIG.C_PROBE27_WIDTH {1} \
    CONFIG.C_PROBE28_WIDTH {64} \
    CONFIG.C_PROBE29_WIDTH {1} \
] [get_ips ila_page_decoder]

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
