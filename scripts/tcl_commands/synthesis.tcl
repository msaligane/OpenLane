# Copyright 2020-2021 Efabless Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

proc get_yosys_bin {} {
    set synth_bin yosys
    if { [info exists ::env(SYNTH_BIN)] } {
		set synth_bin $::env(SYNTH_BIN)
    }
    return $synth_bin
}

proc convert_pg_pins {lib_in lib_out} {
	try_catch sed -E {s/^([[:space:]]+)pg_pin(.*)/\1pin\2\n\1    direction : "inout";/g} $lib_in > $lib_out
}

proc run_yosys {args} {
	set ::env(CURRENT_STAGE) synthesis

	set options {
		{-output optional}
	}
	set flags {
		-no_set_netlist
	}

    parse_key_args "run_yosys" args arg_values $options flags_map $flags

    if { [info exists arg_values(-output)] } {
		set ::env(SAVE_NETLIST) $arg_values(-output)
    } else {
		set ::env(SAVE_NETLIST) $::env(synthesis_results)/$::env(DESIGN_NAME).v
    }
	if { [ info exists ::env(SYNTH_ADDER_TYPE)] && ($::env(SYNTH_ADDER_TYPE) in [list "RCA" "CSA"]) } {
		set ::env(SYNTH_READ_BLACKBOX_LIB) 1
	}

	set ::env(synth_report_prefix) [index_file $::env(synthesis_reports)/synthesis]

    set ::env(LIB_SYNTH_COMPLETE_NO_PG) [list]
	foreach lib $::env(LIB_SYNTH_COMPLETE) {
		set fbasename [file rootname [file tail $lib]]
		set lib_path [index_file $::env(synthesis_tmpfiles)/$fbasename.no_pg.lib]
		convert_pg_pins $lib $lib_path
		lappend ::env(LIB_SYNTH_COMPLETE_NO_PG) $lib_path
	}

	try_catch [get_yosys_bin] \
		-c $::env(SYNTH_SCRIPT) \
		-l [index_file $::env(synthesis_logs)/synthesis.log] \
		|& tee $::env(TERMINAL_OUTPUT)

	if { ! [info exists flags_map(-no_set_netlist)] } {
    	set_netlist $::env(SAVE_NETLIST)
	}

    if { $::env(LEC_ENABLE) && [file exists $::env(PREV_NETLIST)] } {
		logic_equiv_check -rhs $::env(PREV_NETLIST) -lhs $::env(CURRENT_NETLIST)
    }

    # The following is a naive workaround to the defparam issue.. it should be handled with
    # an issue to the OpenROAD verilog parser.
    if { [info exists ::env(SYNTH_EXPLORE)] && $::env(SYNTH_EXPLORE) } {
        puts_info "This is a Synthesis Exploration and so no need to remove the defparam lines."
    } else {
        try_catch sed -i {/defparam/d} $::env(SAVE_NETLIST)
    }
}

proc run_sta {args} {
	set options {
		{-log required}
		{-runtime_log -required} 
	}
    set flags {
		-multi_corner 
	}
    parse_key_args "run_sta" args arg_values $options flags_map $flags
	set multi_corner [info exists flags_map(-multi_corner)]
    set ::env(RUN_STANDALONE) 1
	
	increment_index
	TIMER::timer_start
	puts_info "Running Static Timing Analysis..."

	set log [index_file $arg_values(-log)]

	if {[info exists ::env(CLOCK_PORT)]} {
		if { $multi_corner == 1 } {
			try_catch $::env(OPENROAD_BIN) -exit $::env(SCRIPTS_DIR)/openroad/sta_multi_corner.tcl \
			|& tee $::env(TERMINAL_OUTPUT) $log
		} else {
			try_catch $::env(OPENROAD_BIN) -exit $::env(SCRIPTS_DIR)/openroad/sta.tcl \
			|& tee $::env(TERMINAL_OUTPUT) $log
		}
	} else {
		puts_warn "CLOCK_PORT is not set. STA will be skipped..."
	}
	TIMER::timer_stop
	exec echo "[TIMER::get_runtime]" | python3 $::env(SCRIPTS_DIR)/write_runtime.py "sta - openroad"
}

proc run_synth_exploration {args} {
    puts_info "Running Synthesis Exploration..."

    set ::env(SYNTH_EXPLORE) 1

    run_yosys

    try_catch perl $::env(SCRIPTS_DIR)/synth_exp/analyze.pl [index_file $::env(synthesis_logs).log] > [index_file $::env(synthesis_reports)/exploration_analysis.html]

	# Following two cannot be indexed- referenced by path in the HTML file.
    file copy $::env(SCRIPTS_DIR)/synth_exp/table.css $::env(synthesis_reports)
    file copy $::env(SCRIPTS_DIR)/synth_exp/utils.js $::env(synthesis_reports)
}

proc run_synthesis {args} {
	increment_index
	TIMER::timer_start
    puts_info "Running Synthesis..."
	set ::env(CURRENT_SDC) $::env(BASE_SDC_FILE)
    # in-place insertion
	if { [file exists $::env(synthesis_results)/$::env(DESIGN_NAME).v] } {
		puts_warn "A netlist at $::env(synthesis_results)/$::env(DESIGN_NAME).v already exists..."
		puts_warn "Skipping synthesis"
		set_netlist $::env(synthesis_results)/$::env(DESIGN_NAME).v
	} else {
		run_yosys
	}
    TIMER::timer_stop
    exec echo "[TIMER::get_runtime]" | python3 $::env(SCRIPTS_DIR)/write_runtime.py "synthesis - yosys"

    run_sta -log $::env(synthesis_logs)/sta.log
    set ::env(LAST_TIMING_REPORT_TAG) [index_file $::env(synthesis_reports)/synthesis_sta]
	
    if { $::env(RUN_SIMPLE_CTS) && $::env(CLOCK_TREE_SYNTH) } {
		if { ! [info exists ::env(CLOCK_NET)] } {
			set ::env(CLOCK_NET) $::env(CLOCK_PORT)
		}

		simple_cts \
			-verilog $::env(synthesis_results)/$::env(DESIGN_NAME).v \
			-fanout $::env(CLOCK_BUFFER_FANOUT) \
			-clk_net $::env(CLOCK_NET) \
			-root_clk_buf $::env(ROOT_CLK_BUFFER) \
			-clk_buf $::env(CLK_BUFFER) \
			-clk_buf_input $::env(CLK_BUFFER_INPUT) \
			-clk_buf_output $::env(CLK_BUFFER_OUTPUT) \
			-cell_clk_port $::env(CELL_CLK_PORT) \
			-output $::env(synthesis_results)/$::env(DESIGN_NAME).v
    }

    if { $::env(CHECK_ASSIGN_STATEMENTS) == 1 } {
		check_assign_statements
    }

    if { $::env(CHECK_UNMAPPED_CELLS) == 1 } {
		check_synthesis_failure
    }

	if { [info exists ::env(SYNTH_USE_PG_PINS_DEFINES)] } {
		puts_info "Creating a netlist with power/ground pins."
		if { ! [info exists ::env(SYNTH_DEFINES)] } {
			set ::env(SYNTH_DEFINES) [list]
		}
		lappend ::env(SYNTH_DEFINES) {*}$::env(SYNTH_USE_PG_PINS_DEFINES)
		run_yosys -output $::env(synthesis_tmpfiles)/pg_define.v -no_set_netlist
	}

}

proc verilog_elaborate {args} {
    # usually run on structural verilog (top-level netlists)
    set synth_script_old $::env(SYNTH_SCRIPT)
    set ::env(SYNTH_SCRIPT) $::env(SCRIPTS_DIR)/yosys/synth_top.tcl
    run_yosys {*}$args
    set ::env(SYNTH_SCRIPT) $synth_script_old
}

proc yosys_rewrite_verilog {filename} {
	if { $::env(LEC_ENABLE) || ! [info exists ::env(YOSYS_REWRITE_VERILOG)] || $::env(YOSYS_REWRITE_VERILOG) } {
		if { ! [file exists $filename] } {
			puts_err "$filename does not exist to be re-written"
			return -code error
		}

		set ::env(SAVE_NETLIST) $filename

		increment_index
		TIMER::timer_start
		puts_info "Rewriting $filename into $::env(SAVE_NETLIST)"

		try_catch [get_yosys_bin] \
		-c $::env(SCRIPTS_DIR)/yosys/rewrite_verilog.tcl \
		-l [index_file $::env(synthesis_logs)/rewrite_verilog.log]; #|& tee $::env(TERMINAL_OUTPUT)

		TIMER::timer_stop
		exec echo "[TIMER::get_runtime]" | python3 $::env(SCRIPTS_DIR)/write_runtime.py "verilog rewrite - yosys"
	} else {
		puts_info "Yosys won't attempt to rewrite verilog, and the OpenROAD output will be used as is."
	}
}


proc logic_equiv_check {args} {
	set options {
		{-lhs required}
		{-rhs required}
	}

    set flags {
	}

    set args_copy $args
    parse_key_args "logic_equiv_check" args arg_values $options flags_map $flags
	if { [file exists $arg_values(-lhs).without_power_pins.v] } {
		set ::env(LEC_LHS_NETLIST) $arg_values(-lhs).without_power_pins.v
	} else {
		set ::env(LEC_LHS_NETLIST) $arg_values(-lhs)
	}

	if { [file exists $arg_values(-rhs).without_power_pins.v] } {
		set ::env(LEC_RHS_NETLIST) $arg_values(-rhs).without_power_pins.v
	} else {
		set ::env(LEC_RHS_NETLIST) $arg_values(-rhs)
	}
	increment_index
	TIMER::timer_start
    puts_info "Running LEC: $::env(LEC_LHS_NETLIST) Vs. $::env(LEC_RHS_NETLIST)"

    if {[ catch {\
		exec [get_yosys_bin] \
			-c $::env(SCRIPTS_DIR)/yosys/logic_equiv_check.tcl \
			-l [index_file $::env(synthesis_logs).equiv.log] \
		|& tee $::env(TERMINAL_OUTPUT)\
	} ]} {
	    puts_err "$::env(LEC_LHS_NETLIST) is not logically equivalent to $::env(LEC_RHS_NETLIST)"
		TIMER::timer_stop
		exec echo "[TIMER::get_runtime]" | python3 $::env(SCRIPTS_DIR)/write_runtime.py "logic equivalence check - yosys"
	    return -code error
	}
    puts_info "$::env(LEC_LHS_NETLIST) and $::env(LEC_RHS_NETLIST) are proven equivalent"
	TIMER::timer_stop
    exec echo "[TIMER::get_runtime]" | python3 $::env(SCRIPTS_DIR)/write_runtime.py "logic equivalence check - yosys"
    return -code ok
}

package provide openlane 0.9
