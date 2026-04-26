# OOC clock constraint: 400 MHz target (2.5 ns period).
# OOC critical path measured ~1.76 ns; 400 MHz leaves comfortable margin
# for post-PnR slip while running 1.6× the rest-of-pipeline at 250 MHz
# (CDC FIFO required at the decoder/lob_core boundary).
create_clock -name clk -period 2.500 [get_ports clk]
