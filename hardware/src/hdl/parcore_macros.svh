`ifndef PARCORE_MACROS_SVH_
`define PARCORE_MACROS_SVH_

// Places a skid buffer between the interfaces SIG_NAME and SKID_SIG_NAME
`define SKID_SIGNAL(DTYPE, CLK, RST_N, SIG_NAME, SKID_SIG_NAME)   \
SkidBuffer #(``DTYPE``)                                           \
inst_``SIG_NAME``_``SKID_SIG_NAME``_skidder (                     \
    .clk    (``CLK``),                                            \
    .rst_n  (``RST_N``),                                          \
    .in     (``SIG_NAME``),                                       \
    .out    (``SKID_SIG_NAME``)                                   \
);

`define SKID_DATA_SIGNAL(DTYPE, CLK, RST_N, SIG_NAME, SKID_SIG_NAME)    \
DataSkidBuffer #(``DTYPE``)                                             \
inst_``SIG_NAME``_``SKID_SIG_NAME``_skidder (                           \
    .clk    (``CLK``),                                                  \
    .rst_n  (``RST_N``),                                                \
    .in     (``SIG_NAME``),                                             \
    .out    (``SKID_SIG_NAME``)                                         \
);

`define SKID_NDATA_SIGNAL(DTYPE, N_ELEM, CLK, RST_N, SIG_NAME, SKID_SIG_NAME)   \
NDataSkidBuffer #(``DTYPE``, ``N_ELEM``)                                        \
inst_``SIG_NAME``_``SKID_SIG_NAME``_skidder (                                   \
    .clk    (``CLK``),                                                          \
    .rst_n  (``RST_N``),                                                        \
    .in     (``SIG_NAME``),                                                     \
    .out    (``SKID_SIG_NAME``)                                                 \
);

`endif
