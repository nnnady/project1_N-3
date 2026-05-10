if {[file exists work]} { file delete -force work }
vlib work
vmap work work

# Пакет с классами
vlog -sv tb/tb_pkg.sv

# Интерфейсы
vlog -sv tb/apb_if.sv
vlog -sv tb/parallel_if.sv

# RTL
vlog -sv rtl/apb_slave.sv
vlog -sv rtl/converter_ram.sv
vlog -sv rtl/parallel_master.sv
vlog -sv rtl/converter_fsm.sv
vlog -sv rtl/converter_top.sv

# Верхний тестбенч
vlog -sv tb/tb_converter_top.sv

vsim -voptargs=+acc work.tb_converter_top
add wave -radix hex /tb_converter_top/*
run -all