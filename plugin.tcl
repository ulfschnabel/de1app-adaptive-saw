# plugin.tcl
#
# Adaptive Stop-At-Weight plugin for the Decent Espresso DE1 app.
#
# The DE1's built-in SAW (Stop At Weight) uses a fixed time-based offset
# (stop_weight_before_seconds) to stop the pump early, accounting for
# in-flight water.  That offset is global and not self-correcting.
#
# This plugin:
#   1. Takes ownership of the stop-early offset by zeroing
#      stop_weight_before_seconds and working in grams instead.
#   2. After each espresso shot, computes overshoot (actual - target)
#      and updates a per-profile learned gram offset via EMA.
#   3. Before each shot, injects the learned gram offset into
#      ::device::scale::saw::_early_by_grams so the pump stops at the
#      right time for that specific profile.
#
# Per-profile offsets persist across app restarts via plugin settings.
#
# Compatibility: all profile types (settings_2a/2b/2c), all skins.

set plugin_name "adaptive_saw"

namespace eval ::plugins::adaptive_saw {

    # -------------------------------------------------------------------------
    # Metadata (shown in the plugin selection page)
    # -------------------------------------------------------------------------
    variable author      "Ulf Schnabel"
    variable contact     "ulf.schnabel@gmail.com"
    variable version     0.1
    variable github_repo "ulfschnabel/de1app-adaptive-saw"
    variable name        "Adaptive SAW"
    variable description "Learns per-profile gram offsets for consistent stop-at-weight"

    # -------------------------------------------------------------------------
    # Internal state (not persisted)
    # -------------------------------------------------------------------------
    variable _profile_key  ""    ;# profile active at shot start
    variable _target        0.0  ;# target weight at shot start
    variable _shot_active   0    ;# 1 while an espresso shot is in progress

    # -------------------------------------------------------------------------
    # Main entry point
    # -------------------------------------------------------------------------
    proc main {} {
        variable settings

        # Apply defaults for any missing settings keys
        foreach {key default} {
            alpha      0.4
            max_offset 8.0
        } {
            if { ! [info exists settings($key)] } {
                set settings($key) $default
            }
        }

        # Zero stop_weight_before_seconds — this plugin owns the stop-early
        # offset and works in grams instead of seconds.
        if { $::settings(stop_weight_before_seconds) != 0 } {
            msg -INFO "adaptive_saw: zeroing stop_weight_before_seconds \
(was $::settings(stop_weight_before_seconds)s — now managed by adaptive_saw in grams)"
            set ::settings(stop_weight_before_seconds) 0
            save_settings
        }

        # Register shot lifecycle handlers using the current event API
        ::de1::event::listener::on_major_state_change_add \
            ::plugins::adaptive_saw::_on_major_state_change
        ::de1::event::listener::after_flow_complete_add \
            ::plugins::adaptive_saw::_on_flow_complete

        set nprofiles [_count_saved_offsets]
        msg -INFO "adaptive_saw: ready — $nprofiles profile offset(s) loaded, \
alpha=$settings(alpha), max_offset=$settings(max_offset)g"
    }

    # -------------------------------------------------------------------------
    # Event handlers
    # -------------------------------------------------------------------------

    # Fires on every major state change (Idle->Espresso, Espresso->Idle, etc.)
    # event_dict keys: this_state, previous_state
    proc _on_major_state_change {event_dict} {
        set this_state [dict get $event_dict this_state]

        if { $this_state eq "Espresso" } {
            # Snapshot profile identity and target weight before anything changes.
            set ::plugins::adaptive_saw::_profile_key [_profile_key]
            set ::plugins::adaptive_saw::_target       [_target_weight]
            set ::plugins::adaptive_saw::_shot_active  1

            # Inject the learned gram offset AFTER SAW's own on_espresso_start
            # has run and reset _early_by_grams to 0.
            # "after idle" guarantees we run after all synchronous handlers.
            after idle ::plugins::adaptive_saw::_inject_offset
        }
    }

    # Fires after flow (espresso/hotwater) is complete.
    # We use this rather than on_major_state_change Espresso->Idle because
    # final_espresso_weight is guaranteed to be set by this point.
    proc _on_flow_complete {event_dict} {
        variable settings
        variable _profile_key
        variable _target
        variable _shot_active

        # Guard: only adapt if we saw an espresso shot start
        if { ! $_shot_active } { return }
        set _shot_active 0

        # No valid target recorded
        if { $_target <= 0 || $_profile_key eq "" } { return }

        # Read final weight set by device_scale.tcl during the shot
        if { ! [info exists ::de1(final_espresso_weight)] } { return }
        set actual [expr { double($::de1(final_espresso_weight)) }]

        # Skip adaptation for aborted / very short shots
        if { $actual <= 0 || $actual < $_target * 0.4 } {
            msg -INFO "adaptive_saw: skipping adaptation - \
shot appears aborted (actual=${actual}g, target=${_target}g)"
            return
        }

        set overshoot  [expr { $actual - $_target }]
        set alpha      $settings(alpha)
        set max_offset $settings(max_offset)

        set old_offset [_get_offset $_profile_key]
        set new_offset [expr { $old_offset + $alpha * $overshoot }]

        # Safety clamp: offset must stay in [0, max_offset]
        set new_offset [expr { max(0.0, min($max_offset, $new_offset)) }]

        _set_offset $_profile_key $new_offset
        save_plugin_settings adaptive_saw

        msg -INFO [format \
            "adaptive_saw: '%s'  actual=%.1fg  target=%.1fg  overshoot=%+.2fg  offset %.2f->%.2fg" \
            $_profile_key $actual $_target $overshoot $old_offset $new_offset]
    }

    # -------------------------------------------------------------------------
    # Injection
    # -------------------------------------------------------------------------

    proc _inject_offset {} {
        variable _profile_key

        set offset [_get_offset $_profile_key]

        # Guard against older app versions that may not have this namespace var
        if { [catch {
            set ::device::scale::saw::_early_by_grams $offset
        } err] } {
            msg -WARN "adaptive_saw: could not set _early_by_grams: $err"
            return
        }

        msg -INFO "adaptive_saw: injected ${offset}g for '$_profile_key'"
    }

    # -------------------------------------------------------------------------
    # Profile and target helpers
    # -------------------------------------------------------------------------

    proc _profile_key {} {
        set title [ifexists ::settings(profile_title)]
        if { $title eq "" } { return "default" }
        return $title
    }

    proc _target_weight {} {
        # settings_2c = advanced profile (has its own weight field)
        # anything else uses the standard final_desired_shot_weight
        set profile_type [ifexists ::settings(settings_profile_type)]
        if { $profile_type eq "settings_2c" } {
            set w [ifexists ::settings(final_desired_shot_weight_advanced)]
        } else {
            set w [ifexists ::settings(final_desired_shot_weight)]
        }
        # ifexists returns "" for undefined; coerce to double
        if { $w eq "" } { return 0.0 }
        return [expr { double($w) }]
    }

    # -------------------------------------------------------------------------
    # Per-profile offset storage (backed by plugin settings)
    # -------------------------------------------------------------------------
    # Offsets are stored in the settings array with keys "offset_<profile_title>"

    proc _get_offset {key} {
        variable settings
        set skey "offset_${key}"
        if { [info exists settings($skey)] } {
            return [expr { double($settings($skey)) }]
        }
        return 0.0
    }

    proc _set_offset {key value} {
        variable settings
        set settings(offset_${key}) $value
    }

    proc _count_saved_offsets {} {
        variable settings
        set n 0
        foreach k [array names settings "offset_*"] { incr n }
        return $n
    }

    # -------------------------------------------------------------------------
    # Optional: settings UI page
    # -------------------------------------------------------------------------

    proc build_ui {} {
        variable settings

        set page_name "plugin_adaptive_saw_settings"

        add_de1_page  $page_name "settings_message.png" "default"
        add_de1_text  $page_name 1280 1310 \
            -text [translate "Done"] -font Helv_10_bold \
            -fill "#fAfBff" -anchor "center"
        add_de1_button $page_name \
            {say [translate {Done}] $::settings(sound_button_in); \
             page_to_show_when_off extensions} \
            980 1210 1580 1410 ""

        add_de1_text $page_name 1280 200 \
            -text [translate "Adaptive SAW"] -font Helv_20_bold \
            -width 1200 -fill "#444444" -anchor "center" -justify "center"

        # Description
        add_de1_text $page_name 1280 310 \
            -text [translate "Learns per-profile gram offsets to hit your target weight."] \
            -font Helv_8 -width 1100 -fill "#666666" -anchor "center" -justify "center"

        # Current offsets summary
        set summary [_build_offset_summary]
        add_de1_variable $page_name 640 430 \
            -font Helv_8 -width 1200 -fill "#444444" -anchor "nw" -justify "left" \
            -textvariable {[::plugins::adaptive_saw::_build_offset_summary]}

        # alpha label + value
        add_de1_text $page_name 640 850 \
            -text [translate "Learning rate (alpha):"] \
            -font Helv_8 -fill "#444444" -anchor "nw"
        add_de1_variable $page_name 1100 850 \
            -font Helv_8 -fill "#888888" -anchor "nw" \
            -textvariable {$::plugins::adaptive_saw::settings(alpha)}

        # max_offset label + value
        add_de1_text $page_name 640 950 \
            -text [translate "Max offset (g):"] \
            -font Helv_8 -fill "#444444" -anchor "nw"
        add_de1_variable $page_name 1100 950 \
            -font Helv_8 -fill "#888888" -anchor "nw" \
            -textvariable {$::plugins::adaptive_saw::settings(max_offset)}

        return $page_name
    }

    proc _build_offset_summary {} {
        variable settings
        set lines {}
        foreach k [lsort [array names settings "offset_*"]] {
            set profile [string range $k 7 end]
            set val     $settings($k)
            lappend lines [format "%-32s  %+.2f g" $profile $val]
        }
        if { [llength $lines] == 0 } {
            return "No shots recorded yet."
        }
        return [join $lines "\n"]
    }

} ;# namespace ::plugins::adaptive_saw
