source "board.tcl"
source "$connectaldir/scripts/connectal-synth-ip.tcl"

proc create_custom_pll {refclk args} {
    set num [llength $args]

    if {$num == 0} {
        set error {wrong # args: should be at least "create_custom_pll [refclk] [genclk0] ..."}
        error $error
    }

    puts "Generating PLL with ref clock $refclk and output clock $args..."

    set params [ dict create ]
    dict set params fractional_vco_multiplier "false"
    dict set params reference_clock_frequency $refclk
    dict set params operation_mode            "normal"
    dict set params number_of_clocks          $num

    set m 0
    while {$m < 18} {
        set key0 output_clock_frequency$m
        set key1 phase_shift$m
        set key2 duty_cycle$m
        if {$m < $num} {
            dict set params $key0 [lindex $args $m]
            dict set params $key1 {0 ps}
            dict set params $key2 50
        } else {
            dict set params $key0 {0 MHz}
            dict set params $key1 {0 ps}
            dict set params $key2 50
        }

        incr m
    }

    dict set params pll_type                 "General"
    dict set params pll_subtype              "General"

    set component_parameters {}
	foreach item [dict keys $params] {
		set val [dict get $params $item]
		lappend component_parameters --component-parameter=$item=$val
	}

    set core_name {altera_pll}
    set core_version {14.0}
    set ip_name {altera_pll_wrapper}
    fpgamake_altera_ipcore $core_name $core_version $ip_name $component_parameters
}

create_custom_pll {50 MHz} {125.0 MHz} {156.25 MHz}
