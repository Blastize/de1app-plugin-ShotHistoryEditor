#
# ShotHistoryEditor.tcl -- shot history browser with soft delete (v0.4.0)
# and real metadata save (v0.5.0).
#
# Runtime safety rules:
# - No automatic shot hooks.
# - SDB is opened with a separate read-only sqlite handle. SDB is never
#   written to (no INSERT/UPDATE/DELETE/ALTER/DROP/CREATE TABLE/VACUUM/
#   REINDEX anywhere in this file).
# - Two, and only two, authorized write capabilities against history files:
#   1) Soft delete (v0.4.0): `file rename` MOVES `history/<filename>.shot`
#      and, if present, `history_v2/<filename>.json` into
#      plugins/ShotHistoryEditor/trash/. See perform_delete_batch/
#      restore_batch. Content is never edited by this path.
#   2) Real metadata save (v0.5.0): perform_metadata_edit rewrites ONLY the
#      one targeted key line inside history/<filename>.shot's settings{}
#      block (via a verified temp-file + atomic `file rename`), after first
#      copying the whole original file to plugins/ShotHistoryEditor/
#      backups/. Every other byte of the file -- including the raw sensor
#      arrays -- is preserved untouched. (v0.24.0: the shot's history_v2
#      .json then gets the same field -- write capability 10, below.)
# - `file delete` is never called on a history file anywhere in this file.
# - Raw chart and sensor arrays are never displayed for editing and never
#   modified by either write path.
# - v0.17.0 bag Save (write capability 7): perform_bag_save rewrites the
#   changed bag settings (bean_brand, bean_type, bean_notes, roast_date,
#   roast_level) in every history/<f>.shot of one bag after a typed file
#   count -- verified backups first, binary-exact rewrite of only those
#   entries, read-back checks, restore on failure, write-ahead edit_log.
#   No file delete; SDB never written (history_v2: see v0.24.0).
# - v0.19.0 next-shot update (write capability 8): after a bag Save that
#   wrote files, when DYE's next-shot plan names exactly the saved bag,
#   _bag_next_apply applies the changed bag fields to it through DYE's own
#   get_next + source_next_from (BeanScanner's call), logged BAGSAVE NEXT
#   BEGIN / OK | FAILED | SKIPPED. SHE never writes ::settings or DYE's
#   settings itself.
# - v0.20.0 paths: history/ and history_v2/ are found under the app's data
#   root (_data_root: data_directory, else homedir -- the same folder on
#   every platform today); SHE's own trash, backups, manifests and logs stay
#   in plugins/ShotHistoryEditor/ (_she_data_dir); a trash record's stored
#   path is rebased onto the current history folders before any disk use
#   (_rebased_orig). No new write capability.
# - v0.21.0: Advanced > Move trash and logs... PREVIEWS the later move of
#   SHE's own files to [_data_root]/history_trash (what would move, every
#   reason it would refuse). Read-only.
# - v0.22.0 one-time move (write capability 9): perform_she_move renames
#   SHE's OWN 8 items from the plugin folder into [_data_root]/history_trash
#   after a typed count (rename only, one device; rollback on failure, roll
#   forward after a crash). _she_data_dir follows the files: the plugin
#   folder until the move, history_trash after it and on a fresh install.
#   While a move is unfinished or the files are in two places, every SHE
#   write is refused (_she_write_blocker). Trash-record appends are no
#   longer swallowed; the purge log is write-ahead.
# - v0.23.0: history_v2 PREVIEW -- Edit Preview shows what a later version
#   would change in the shot's history_v2/<ts>.json (only the edited field's
#   meta and app.data.settings values), checked in memory; bag Review counts
#   the copies. Nothing writes history_v2. The single-field save now refuses
#   braces/backslashes, a busy DE1 and an SDB sync, like the bag Save.
# - v0.23.1 (review of the move, before its first real run): the manifest
#   is read whole or not at all and must keep the plan's line count; a
#   manifest that cannot be put back keeps every item in staging; "put
#   back" is checked on the disk; the delete result tells the truth when a
#   batch was put back; no trash or edit append is a bare catch.
# - v0.23.2 (review before the move): Restore and Empty trash read the
#   trash manifest whole or refuse, and every manifest change (delete,
#   restore, purge) is one _manifest_write: temp file, read back, rename;
#   lines it cannot parse are kept. A Finish move never rewrites a manifest
#   with nothing left to re-point. The history_v2 preview cannot throw; its
#   lines fit one row each. A failed single-field save is put back from its
#   checked backup by copy and checked; restore failures are counted.
# - v0.23.3 (review of 0.23.2): Restore, Empty trash and the move read the
#   manifest with must_exist (a stat that says "no file" refuses instead of
#   reading empty); Restore refuses a batch the manifest does not name and
#   does not rewrite when it drops no line; the result pages read
#   refresh_note with _dget (no catch); a trash folder that cannot be made
#   gives a normal delete result.
# - v0.24.0 FIRST history_v2 WRITE (write capability 10): after a .shot
#   write is made, verified and logged (single-field Save, each file of a
#   bag Save), _v2_save changes the same field(s) in history_v2/<ts>.json:
#   only the mapped string values, patched in memory and re-read with tcllib
#   json, a checked backup, write-ahead V2 BEGIN, temp + read-back + one
#   rename, restore from the backup on a bad rename/read-back. A v2 result
#   never undoes or stops the .shot write. No .json: left alone.
#

catch { package require sqlite3 }
catch { package require json }

namespace eval ::plugins::ShotHistoryEditor {
    variable db_handle ::plugins::ShotHistoryEditor::__sdb_ro
    variable recent_rows {}
    variable selected_row {}
    variable last_error ""
    variable table_used ""
    variable detected_objects {}
    # v0.8.6: 7 (was 8) so the Source Inspector's Open buttons reach the
    # design-system 60 px touch minimum inside their row band. The page's
    # row count, the refresh loop and the SQL scan cap all read this.
    variable max_recent 7
    variable detail_page_index 0
    variable diagnostics_page_index 0
    variable help_page_index 0
    variable delete_review_page_index 0
    # v0.10.0: the reconciliation view is a row list with an Unhide button per
    # row (was paged text in v0.9.0); same pager shape as the Trash page.
    variable reconcile_offset 0
    variable reconcile_page_size 6
    variable reconcile_note ""
    # v0.11.0: "Empty trash" PREVIEW page (paged text). Nothing is deleted in
    # this version; see empty_trash_preview_text.
    variable empty_preview_page_index 0
    # v0.21.0: the history_trash move preview (read-only).
    variable migrate_preview_page_index 0
    # v0.22.0: the move's typed confirmation (the plan snapshot and the count
    # it is typed for, taken when the confirmation page shows) and its result.
    variable migrate_input ""
    variable migrate_error ""
    variable migrate_snap ""
    variable migrate_count ""
    variable migrate_result_text "No move has run yet."
    # v0.12.0: real Empty trash. Snapshot of the batch ids taken when the
    # confirmation opens (perform_purge refuses if the set changed), the typed
    # confirmation, and the result text.
    variable purge_batch_ids {}
    variable purge_input ""
    variable purge_error ""
    variable purge_result_text ""
    # v0.13.0: the Tidy result line. v0.15.2: shown under the Trash page's
    # status (Tidy moved there) until that page is next shown.
    variable tidy_note ""
    variable page_line_count 22
    variable editable_fields {grinder_setting grinder_dose_weight drink_weight bean_brand bean_type espresso_notes my_name drinker_name}
    variable edit_field "grinder_setting"
    variable edit_new_value ""
    variable edit_preview_text "Preview only - no files will be modified."
    variable edit_warning ""
    variable edit_return_page "ShotHistoryEditor_settings"

    # v0.5.2: captured by the Settings page's own show{} (see
    # _capture_return_page below) -- the real DE1app page that opened this
    # plugin, so the Settings page's Done button can navigate straight back
    # to it instead of trusting the framework's own "previous page" stack.
    variable _settings_return_page ""

    # Pass 3 -- main-page card list state (all still read-only; see card_rows/sel below).
    variable card_rows {}
    variable card_page_size 5
    variable card_offset 0
    variable select_mode 0
    array set sel {}
    variable delete_target_count 0

    # Pass 3.1 -- design-system layout tokens, computed once in _init_layout from the
    # real detected screen size (see that proc for the full token table). Everything in
    # this plugin's UI is positioned from this array; no page should hardcode coordinates.
    array set L {}

    # Pass 4.0 -- real soft delete state. review_filenames/review_rows are a
    # snapshot taken the moment Delete is pressed, so the Review/Confirm flow
    # stays correct even if the underlying card list re-pages later. Nothing
    # here is a guard flag that could get stuck: every navigation into or out
    # of the delete flow goes through open_page, and the settings page's own
    # `show` proc already unconditionally resets select_mode/sel (v0.3.0
    # lesson), which is what actually exits the flow safely on Cancel.
    variable review_filenames {}
    variable review_rows {}
    variable confirm_input ""
    variable confirm_error ""
    variable delete_result_text ""
    variable trash_offset 0
    # v0.14.0 (F6): five cards per page, the house list (was six text rows).
    variable trash_page_size 5
    # v0.15.1 (F13): pages drawn by the shared builders -- _page_bg,
    # _subpage_header (page -> title role), _add_back and _add_pager (page ->
    # its two pager tags). _retheme_all walks all four, so a page built with
    # them is repainted without editing any list (its own other items still
    # need their entries).
    variable bg_pages {}
    variable header_roles
    array set header_roles {}
    variable back_pages {}
    variable pager_tags
    array set pager_tags {}

    # Pass 5.0 -- real metadata save state. Snapshot taken the moment "Save
    # Change" is pressed on Edit Preview, so the Confirm/Result flow stays
    # correct even if the field selector is touched again later. As with
    # delete, there is no guard flag that can strand a button: every
    # navigation uses open_page (forward) or _return_to_page (back to an
    # ancestor), and edit_return_page is where the whole edit+confirm+result
    # mini-flow always returns to.
    variable edit_confirm_filename ""
    variable edit_confirm_field ""
    variable edit_confirm_old_value ""
    variable edit_confirm_new_value ""
    variable edit_result_text ""
}

# v0.8.3: the core logger honours a severity flag (-NOTICE, -INFO, ...)
# only in argument position one (logging.tcl default_logger). This wrapper
# used to put the namespace first, so every flagged call logged at the
# default INFO level with the flag as literal text. A leading flag is now
# hoisted ahead of the namespace, matching how the core itself calls msg.
proc ::plugins::ShotHistoryEditor::msg {args} {
    if {[string index [lindex $args 0] 0] eq "-"} {
        catch { ::msg [lindex $args 0] [namespace current] {*}[lrange $args 1 end] }
    } else {
        catch { ::msg [namespace current] {*}$args }
    }
}

# ---------------------------------------------------------------------------
# Pass 3.1 -- design-system layout tokens.
#
# Pass 3.2 bugfix note (v0.3.1 rendered at ~half size, top-left, with
# overlapping card text):
#
# v0.3.1's comment above was wrong. DE1app fpdialog pages are NOT drawn at
# real physical screen pixels -- they are drawn in a fixed VIRTUAL coordinate
# space that the dui framework itself rescales to whatever the physical
# screen actually is. Re-inspecting the reference plugins confirms this:
# SDB.tcl:3254 centers its page title at x=1280 (exactly half of 2560), and
# GrindAdvisor.tcl repeatedly places fpdialog buttons at y up to ~1580-1600
# (GrindAdvisor.tcl:1720 etc: "dui add dbutton $page 980 1375 1580 1495").
# Those coordinates are far larger than any physical tablet screen, so they
# only make sense in a virtual canvas of roughly 2560x1600 -- 2x the
# 1340x800 physical reference. The one confirmed dui coordinate-scaling API
# in this workspace, `dui::platform::rescale_x`/`rescale_y`
# (plugins/visualizer_upload/plugin.tcl:509), exists precisely to convert a
# value from that virtual space to physical pixels, which only makes sense
# if `dui add dtext/dbutton/canvas_item` coordinates are themselves expected
# in virtual-space units -- dui does the physical conversion for us. No
# constant literally named "2560"/"1600" is declared anywhere in this
# workspace (checked plugins/SDB, plugins/GrindAdvisor,
# plugins/visualizer_upload, skins/*/skin.tcl again for this pass); the
# virtual size is only inferable from the coordinates plugins actually draw
# at, so it is hardcoded below as the two constants VIRTUAL_W/VIRTUAL_H.
#
# v0.3.1 fed `winfo screenwidth/screenheight` (the REAL physical size, e.g.
# 1340x800) into every coordinate formula. Since dui treats all incoming
# coordinates as virtual-space (~2560x1600) and rescales them down to the
# real physical screen regardless, our already-physical-sized coordinates
# got shrunk a second time (physical 1340x800 treated as if it were
# 2560x1600 virtual -> rescaled by roughly 1340/2560 ~= 0.52), which is
# exactly the "half size, top-left" symptom (bottom bar and right edge never
# reached, because our right_x/bar_y0 were themselves only ~52% of where
# they needed to be).
#
# Font sizes are a separate problem: our SHE_* fonts are plain Tk font
# objects created with `font create ... -size -N` (negative = literal
# pixels) and referenced by name via `-font`. dui has no way to intercept or
# rescale an arbitrary Tk font object handed to it this way -- `-font` is
# passed straight through to the underlying canvas text item, so whatever
# pixel size we create it at is what renders, completely unaffected by
# dui's coordinate rescale. That means fonts must be sized for the REAL
# physical screen (so they render at the intended physical pixel size),
# while coordinates must be computed in the virtual space (so dui's own
# rescale lands them in the right physical place). v0.3.1 used one scale
# factor for both from the same (real, physical) screen_h -- coincidentally
# correct for fonts, but wrong for coordinates, which is why fonts looked
# oversized relative to the doubly-shrunk card spacing and the baselines
# collided. This pass introduces two independent scale factors from two
# different sources for exactly that reason: `scale` (coordinates, from the
# fixed virtual base resolution) and `font_scale` (fonts, from the real
# detected physical screen, same winfo pattern as before).
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
#  Theme palette (v0.8.0). Every color the plugin paints comes from these
#  tokens, chosen per settings(theme) (light | dark, default light, persisted
#  in the plugin's own settings.tdb -- this plugin's first persisted setting).
#  Called from _init_layout at startup and from toggle_theme at runtime.
#
#  v0.13.2 (contrast batch; the same values as GrindAdvisor,
#  MaintenanceTracker and BeanScanner): WCAG 2.1 at the tablet's rendered
#  sizes (fonts scale by 736/800 = 0.92: button 18 bold, body 17 and caption
#  16 need 4.5:1; title, section and primary 3:1). Button labels are a
#  palette token now; they were white in both themes, 1.70:1 on the light
#  periwinkle. Ratios after the change (before):
#    text_mut        dark  #9aa0ad  card 4.66 (3.93), page 5.82
#                    light #595959  page 4.86 (3.98), card 6.78
#    danger          dark  #ffb8b2  button label 4.54 (3.28), page 9.27
#                    light #962219  caption 5.73 (3.77), button label 4.86 (3.19)
#    value_blue      light #2753bb  page 4.79 (2.43), entry 6.65 (3.38)
#    btn_label_fill  dark  #ffffff  7.48;  light #2b2b2b  8.32 (1.70)
#  Disabled labels stay #999999 (exempt, quieter than the enabled label).
# ---------------------------------------------------------------------------

proc ::plugins::ShotHistoryEditor::_apply_palette {} {
    variable L
    variable settings
    set dark 0
    catch { if {$settings(theme) eq "dark"} { set dark 1 } }
    if {$dark} {
        set L(page_bg)      "#23252e"
        set L(card_bg)      "#32353f"
        set L(card_outline) "#464b58"
        set L(text_hi)      "#e8e9ee"
        set L(text_body)    "#c2c5cf"
        set L(text_mut)     "#9aa0ad"
        set L(danger)       "#ffb8b2"
        set L(warn)         "#e0a860"
        set L(value_blue)   "#8ab4ff"
        set L(entry_bg)     "#3a3e4a"
        set L(entry_danger_bg) "#4a3438"
        set L(btn_fill)     "#4a5473"
        set L(btn_disabled_fill) "#3a3e4a"
        set L(btn_label_fill) "#ffffff"
        set L(btn_label_disabled) "#999999"
        # v0.15.0 (F12): a selected card -- blue-tinted with a value-blue
        # outline; every card text keeps >= 4.99:1 on the tint.
        set L(card_sel_bg)      "#26304a"
        set L(card_sel_outline) "#8ab4ff"
        # v0.18.1: the Shots | Bags box, a shade off the page (text_body on
        # it 7.97:1).
        set L(seg_bg)       "#2a2d37"
        set L(seg_outline)  "#3d414d"
    } else {
        set L(page_bg)      "#d5d6e3"   ;# stock settings-page grey
        set L(card_bg)      "#fbfbfd"
        set L(card_outline) "#dcdcdc"
        set L(text_hi)      "#2b2b2b"
        set L(text_body)    "#444444"
        set L(text_mut)     "#595959"
        set L(danger)       "#962219"
        set L(warn)         "#7a4b00"
        set L(value_blue)   "#2753bb"
        set L(entry_bg)     "#fbfaff"
        set L(entry_danger_bg) "#fff5f5"
        set L(btn_fill)     "#c0c5e3"   ;# stock dbutton periwinkle
        set L(btn_disabled_fill) "#dddddd"
        set L(btn_label_fill) "#2b2b2b"
        set L(btn_label_disabled) "#999999"
        # v0.15.0 (F12): selected card tint (texts >= 5.87:1 on it).
        set L(card_sel_bg)      "#e3ebff"
        set L(card_sel_outline) "#2753bb"
        # v0.18.1: the Shots | Bags box (text_body on it 7.91:1).
        set L(seg_bg)       "#e6e7f0"
        set L(seg_outline)  "#c3c6d6"
    }
    # v0.15.0 (F12): the "Delete N" bar button in Select mode -- the danger
    # face MaintenanceTracker uses, white label 6.54:1, both themes.
    set L(btn_danger_fill)  "#b3261e"
    set L(btn_danger_label) "#ffffff"
    # v0.16.0: Bags view and cleaning-run tokens.
    _apply_bag_palette $dark
}

proc ::plugins::ShotHistoryEditor::_glyph_for {name} {
    set glyph ""
    catch {
        if {[dui symbol exists $name]} { set glyph [dui symbol get $name] }
    }
    return $glyph
}

# v0.8.5: label glyphs (pencil, arrows, checkboxes) are built from their
# code points so the source stays plain ASCII (CLAUDE.md rule) and no editor
# or tool can mangle a raw character or a backslash escape. Every label that
# uses one keeps its plain-text word beside it as the fallback.
proc ::plugins::ShotHistoryEditor::_u {code} {
    return [format %c $code]
}

# Moon in light mode (tap for dark), sun-bright in dark; text fallback.
proc ::plugins::ShotHistoryEditor::_theme_button_face {} {
    variable L
    variable settings
    set dark 0
    catch { if {$settings(theme) eq "dark"} { set dark 1 } }
    if {[info exists L(have_icons)] && $L(have_icons)} {
        set g [_glyph_for [expr {$dark ? "sun-bright" : "moon"}]]
        if {$g ne ""} { return $g }
    }
    return [expr {$dark ? [translate "Light"] : [translate "Dark"]}]
}

proc ::plugins::ShotHistoryEditor::toggle_theme {} {
    variable settings
    set settings(theme) [expr {$settings(theme) eq "dark" ? "light" : "dark"}]
    catch { plugins save_settings ShotHistoryEditor }
    _apply_palette
    _retheme_all
    catch { dui item config ShotHistoryEditor_settings btn_theme -label [_theme_button_face] }
    catch { msg "ShotHistoryEditor: theme switched to $settings(theme)" }
}

# Repaint every palette-colored item by bare tag on all 17 pages. All
# colors in this plugin are creation-time (no refresh reconfigures a
# fill), so this walk IS the complete repaint. Buttons restyle through
# their -btn shape tags and, v0.13.2, their -lbl label tags with
# L(btn_label_fill) (labels used to stay white in both themes); the five
# danger-labeled buttons then get L(danger) back in the last loop.
# v0.13.2: the she_btn style follows the palette too, so a page whose
# setup{} only runs after a toggle (dui sets a page up on its first load
# when the plugin was enabled mid-session) draws its buttons in the
# current theme instead of the one the plugin loaded in.
proc ::plugins::ShotHistoryEditor::_retheme_all {} {
    variable L
    catch {
        dui aspect set -theme default -type dbutton -style she_btn [list \
            fill $L(btn_fill) disabledfill $L(btn_disabled_fill)]
        dui aspect set -theme default -type dbutton_label -style she_btn [list \
            fill $L(btn_label_fill) disabledfill $L(btn_label_disabled)]
    }
    # v0.15.1: every page that drew its background with _page_bg (all 17).
    variable bg_pages
    foreach p $bg_pages {
        catch { dui item config $p page_bg -fill $L(page_bg) -outline $L(page_bg) }
    }
    # Text roles: {page tag role} triplets.
    foreach {p tag role} {
        ShotHistoryEditor_settings page_title text_hi
        ShotHistoryEditor_settings subtitle text_mut
        ShotHistoryEditor_settings recent_status text_mut
        ShotHistoryEditor_advanced deleted_note warn
        ShotHistoryEditor_delete_review review_count_text text_body
        ShotHistoryEditor_delete_review review_intro text_mut
        ShotHistoryEditor_delete_review review_page_status text_mut
        ShotHistoryEditor_delete_review review_text text_body
        ShotHistoryEditor_delete_confirm confirm_instructions text_body
        ShotHistoryEditor_delete_confirm confirm_error_text danger
        ShotHistoryEditor_delete_result result_text text_body
        ShotHistoryEditor_edit_confirm confirm_shot_text text_body
        ShotHistoryEditor_edit_confirm confirm_file_text text_mut
        ShotHistoryEditor_edit_confirm confirm_field_text text_body
        ShotHistoryEditor_edit_confirm confirm_before_text text_body
        ShotHistoryEditor_edit_confirm confirm_after_text danger
        ShotHistoryEditor_edit_confirm confirm_warning_text warn
        ShotHistoryEditor_edit_confirm confirm_v2_text text_mut
        ShotHistoryEditor_edit_result edit_result_text text_body
        ShotHistoryEditor_trash trash_status text_mut
        ShotHistoryEditor_recent recent_status text_mut
        ShotHistoryEditor_recent header text_body
        ShotHistoryEditor_detail detail_page_status text_mut
        ShotHistoryEditor_detail detail_text text_body
        ShotHistoryEditor_edit_preview selected_shot text_body
        ShotHistoryEditor_edit_preview editable_source text_mut
        ShotHistoryEditor_edit_preview fs_label text_body
        ShotHistoryEditor_edit_preview field_value value_blue
        ShotHistoryEditor_edit_preview cv_label text_body
        ShotHistoryEditor_edit_preview current_value text_body
        ShotHistoryEditor_edit_preview preview_status warn
        ShotHistoryEditor_edit_preview preview_text text_body
        ShotHistoryEditor_diagnostics diagnostics_page_status text_mut
        ShotHistoryEditor_diagnostics diagnostics_text text_body
        ShotHistoryEditor_help help_page_status text_mut
        ShotHistoryEditor_help help_text text_body
        ShotHistoryEditor_reconcile reconcile_status text_mut
        ShotHistoryEditor_reconcile header text_body
        ShotHistoryEditor_empty_preview empty_preview_page_status text_mut
        ShotHistoryEditor_empty_preview empty_preview_text text_body
        ShotHistoryEditor_migrate_preview migrate_preview_page_status text_mut
        ShotHistoryEditor_migrate_preview migrate_preview_text text_body
        ShotHistoryEditor_migrate_confirm migrate_instructions text_body
        ShotHistoryEditor_migrate_confirm migrate_error_text danger
        ShotHistoryEditor_migrate_confirm migrate_summary text_mut
        ShotHistoryEditor_migrate_result migrate_result_text text_body
        ShotHistoryEditor_purge_confirm purge_instructions text_body
        ShotHistoryEditor_purge_confirm purge_error_text danger
        ShotHistoryEditor_purge_result purge_result_text text_body
    } {
        catch { dui item config $p $tag -fill $L($role) }
    }
    # v0.15.1 (F13): every sub-page header drawn by _subpage_header (its
    # title in the role it registered, the subtitle muted).
    variable header_roles
    foreach p [array names header_roles] {
        catch { dui item config $p page_title -fill $L($header_roles($p)) }
        catch { dui item config $p subtitle -fill $L(text_mut) }
    }
    # v0.15.2 (F18): Advanced's two section cards.
    foreach c {sec_recover sec_inspect} {
        catch { dui item config ShotHistoryEditor_advanced ${c}_bg -fill $L(card_bg) -outline $L(card_outline) }
        catch { dui item config ShotHistoryEditor_advanced ${c}_title -fill $L(text_hi) }
    }
    # Card rows on the main page, and (v0.14.0, F6) the Trash cards -- only
    # the slots that exist (a missing tag is a DEBUG line per config).
    variable trash_page_size
    for {set i 0} {$i < 12} {incr i} {
        set pages ShotHistoryEditor_settings
        if {$i < $trash_page_size} { lappend pages ShotHistoryEditor_trash }
        foreach p $pages {
            catch { dui item config $p row${i}_bg \
                -fill $L(card_bg) -outline $L(card_outline) }
            catch { dui item config $p row${i}_line1 -fill $L(text_hi) }
            catch { dui item config $p row${i}_line2 -fill $L(text_body) }
            catch { dui item config $p row${i}_line3 -fill $L(text_mut) }
        }
        catch { dui item config ShotHistoryEditor_recent row${i}_text -fill $L(text_body) }
        catch { dui item config ShotHistoryEditor_reconcile row${i}_text -fill $L(text_body) }
    }
    # Entries (Tk widgets; their attached labels are -lbl sub-items).
    catch { dui item config ShotHistoryEditor_delete_confirm confirm_entry \
        -bg $L(entry_danger_bg) -foreground $L(danger) }
    catch { dui item config ShotHistoryEditor_delete_confirm confirm_entry-lbl -fill $L(text_body) }
    catch { dui item config ShotHistoryEditor_purge_confirm purge_entry \
        -bg $L(entry_danger_bg) -foreground $L(danger) }
    catch { dui item config ShotHistoryEditor_purge_confirm purge_entry-lbl -fill $L(text_body) }
    catch { dui item config ShotHistoryEditor_migrate_confirm migrate_entry \
        -bg $L(entry_bg) -foreground $L(value_blue) }
    catch { dui item config ShotHistoryEditor_migrate_confirm migrate_entry-lbl -fill $L(text_body) }
    catch { dui item config ShotHistoryEditor_edit_preview new_value \
        -bg $L(entry_bg) -foreground $L(value_blue) }
    catch { dui item config ShotHistoryEditor_edit_preview new_value-lbl -fill $L(text_body) }
    # Buttons: shape fills, then labels (v0.13.2: btn_label_fill per theme;
    # the five danger labels are set again right after this loop).
    foreach {p tags} {
        ShotHistoryEditor_settings {mode_btn bar_left bar_right btn_theme
                                    row0_btn row1_btn row2_btn row3_btn row4_btn}
        ShotHistoryEditor_advanced {source_inspector diagnostics help_guide trash_restore reconcile
                                    migrate_preview}
        ShotHistoryEditor_delete_review {cancel continue_btn}
        ShotHistoryEditor_delete_confirm {cancel confirm_delete}
        ShotHistoryEditor_delete_result {page_done}
        ShotHistoryEditor_edit_confirm {cancel save_change}
        ShotHistoryEditor_edit_result {page_done}
        ShotHistoryEditor_trash {empty_preview tidy
                                 row0_restore row1_restore row2_restore row3_restore
                                 row4_restore}
        ShotHistoryEditor_recent {row0_open row1_open row2_open row3_open
                                  row4_open row5_open row6_open}
        ShotHistoryEditor_detail {edit_preview}
        ShotHistoryEditor_edit_preview {next_field preview_change save_change}
        ShotHistoryEditor_reconcile {row0_unhide row1_unhide row2_unhide row3_unhide
                                     row4_unhide row5_unhide}
        ShotHistoryEditor_empty_preview {empty_now}
        ShotHistoryEditor_migrate_preview {migrate_now}
        ShotHistoryEditor_migrate_confirm {cancel migrate_confirm_btn}
        ShotHistoryEditor_migrate_result {page_done}
        ShotHistoryEditor_purge_confirm {cancel purge_confirm_btn}
        ShotHistoryEditor_purge_result {page_done}
    } {
        foreach t $tags {
            catch { dui item config $p ${t}-btn \
                -fill $L(btn_fill) -outline $L(btn_fill) \
                -disabledfill $L(btn_disabled_fill) -disabledoutline $L(btn_disabled_fill) }
            catch { dui item config $p ${t}-lbl -fill $L(btn_label_fill) }
        }
    }
    # v0.15.1 (F13): every Back drawn by _add_back and every pager drawn by
    # _add_pager.
    variable back_pages
    variable pager_tags
    set reg {}
    foreach p $back_pages { lappend reg $p back }
    foreach p [array names pager_tags] {
        foreach t $pager_tags($p) { lappend reg $p $t }
    }
    foreach {p t} $reg {
        catch { dui item config $p ${t}-btn \
            -fill $L(btn_fill) -outline $L(btn_fill) \
            -disabledfill $L(btn_disabled_fill) -disabledoutline $L(btn_disabled_fill) }
        catch { dui item config $p ${t}-lbl -fill $L(btn_label_fill) }
    }
    foreach {p t} {
        ShotHistoryEditor_delete_confirm confirm_delete
        ShotHistoryEditor_edit_confirm save_change
        ShotHistoryEditor_edit_preview save_change
        ShotHistoryEditor_empty_preview empty_now
        ShotHistoryEditor_purge_confirm purge_confirm_btn
    } {
        catch { dui item config $p ${t}-lbl -fill $L(danger) }
    }
    # v0.16.0: the Bags pages, the Shots/Bags tabs and the cleaning pills
    # (before the selection look below, which the card fills defer to).
    _retheme_bag_pages
    # v0.15.0 (F12): the walk above painted every card plain and bar_left in
    # the normal style; selected cards and Select mode's "Delete N" face
    # take their look back (the theme toggle sits on the card page itself).
    _paint_all_card_sel ShotHistoryEditor_settings
    _refresh_select_bar ShotHistoryEditor_settings
}

proc ::plugins::ShotHistoryEditor::_init_layout {} {
    variable L
    array unset L
    array set L {}

    # Virtual base resolution: fixed constants, not detected. Every token
    # below keeps its exact v0.3.1 formula; only this input changed.
    set sw 2560
    set sh 1600
    set scale [expr {double($sh) / 800.0}]

    # Real physical screen, used ONLY for font pixel sizes (see note above).
    set psw 1340
    set psh 800
    catch { set psw [winfo screenwidth .] }
    catch { set psh [winfo screenheight .] }
    if {$psw <= 1} { set psw 1340 }
    if {$psh <= 1} { set psh 800 }
    set font_scale [expr {double($psh) / 800.0}]

    set L(screen_w) $sw
    set L(screen_h) $sh
    set L(scale) $scale
    set L(physical_screen_w) $psw
    set L(physical_screen_h) $psh
    set L(font_scale) $font_scale

    # Spacing tokens (reference px at 1340x800, scaled by screen factor).
    foreach {tok ref} {xs 6 sm 10 md 16 lg 24 xl 32 xxl 48} {
        set L($tok) [expr {int(round($ref * $scale))}]
    }

    set L(margin) [expr {int(max($sw * 0.036, 32))}]
    set L(left_x) $L(margin)
    set L(right_x) [expr {$sw - $L(margin)}]
    set L(content_w) [expr {$L(right_x) - $L(left_x)}]
    set L(label_col_w) [expr {int(round(420 * $scale))}]
    set L(value_x) [expr {$L(left_x) + $L(label_col_w) + $L(lg)}]

    set L(card_w) $L(content_w)
    set L(card_h) [expr {int(round(96 * $scale))}]
    set L(card_gap) [expr {int(round(12 * $scale))}]
    set L(card_pad_x) [expr {int(round(18 * $scale))}]
    set L(card_pad_y) [expr {int(round(14 * $scale))}]
    set L(card_line1_dy) [expr {int(round(30 * $scale))}]
    set L(card_line2_dy) [expr {int(round(56 * $scale))}]
    set L(card_line3_dy) [expr {int(round(80 * $scale))}]

    set L(btn_w_std) [expr {int(round(200 * $scale))}]
    set L(btn_w_wide) [expr {int(round(240 * $scale))}]
    # v0.13.1: Shot Detail's Edit Metadata Preview, now a left-group button.
    set L(btn_w_xwide) [expr {int(round(300 * $scale))}]
    set L(btn_h) [expr {int(max(60, round(60 * $scale)))}]
    set L(card_btn_w) [expr {int(round(150 * $scale))}]
    set L(card_btn_h) [expr {int(max(56, round(56 * $scale)))}]
    set L(btn_radius) [expr {int(round(12 * $scale))}]
    set L(card_radius) $L(btn_radius)

    # v0.5.4: self-contained colors (BeanScanner v0.1.2 pattern). The plugin
    # paints its own page background and its button style carries explicit
    # fills, so nothing depends on which dui theme or skin palette happens
    # to be current when this plugin loads or renders.
    # v0.8.0: every color token lives in _apply_palette (light / dark, per
    # settings(theme)) so the sun/moon toggle can swap it at runtime.
    # v0.13.2: the button label colors too (a theme-blind white was set here).
    _apply_palette

    set L(header_y1) [expr {int(round(96 * $scale))}]
    # Fixed header baselines (not fractions of header_y1) so title/subtitle
    # always keep at least an "md" gap between their text blocks -- an
    # earlier draft used header_y1*0.42/0.8 fractions which left only ~3px
    # between the two lines at some scales, effectively touching.
    set L(header_title_y) [expr {int(round(28 * $scale))}]
    set L(header_subtitle_y) [expr {int(round(72 * $scale))}]
    # v0.15.1 (F13): header_solo_title_y is gone -- every sub-page now has
    # the title + subtitle header (_subpage_header).
    set L(toolbar_y0) [expr {int(round(104 * $scale))}]
    set L(toolbar_y1) [expr {int(round(152 * $scale))}]
    set L(list_top) [expr {int(round(168 * $scale))}]
    # v0.18.1 (owner mockup 2026-10-02): the toolbar row holds the Shots |
    # Bags switch (one rounded box at left_x, the active side filled), the
    # status (centred) and Select (the card buttons' column, shorter than a
    # bar button, centred on the row).
    set L(toolbar_mid_y) [expr {($L(toolbar_y0) + $L(toolbar_y1)) / 2}]
    set L(seg_w) [expr {int(round(264 * $scale))}]
    set L(seg_inset) [expr {int(round(5 * $scale))}]
    set L(seg_radius) [expr {int(round(10 * $scale))}]
    set L(seg_btn_radius) [expr {int(round(8 * $scale))}]
    set L(sel_btn_h) [expr {int(round(42 * $scale))}]
    set L(sel_x1) [expr {$L(right_x) - $L(card_pad_x)}]
    set L(sel_x0) [expr {$L(sel_x1) - $L(card_btn_w)}]
    set mid_x [expr {($L(left_x) + $L(right_x)) / 2}]
    set L(toolbar_status_w) [expr {2 * min($mid_x - $L(left_x) - $L(seg_w) - $L(md), $L(sel_x0) - $L(md) - $mid_x)}]
    # v0.15.2 (F18): section cards (Advanced), GrindAdvisor's tokens -- pad
    # lg, a 24 px section-title band, two columns an lg gutter apart.
    set L(sec_pad) $L(lg)
    set L(sec_title_h) [expr {int(round(24 * $scale))}]
    set L(sec_gutter) $L(lg)
    set L(sec_col_w) [expr {($L(content_w) - $L(sec_gutter)) / 2}]
    set L(sec_col2_x) [expr {$L(left_x) + $L(sec_col_w) + $L(sec_gutter)}]
    set L(bar_y0) [expr {int(round(716 * $scale))}]
    set L(bar_y1) [expr {int(round(776 * $scale))}]

    # Pixel-exact fonts (Tk convention: negative -size means pixels, not points),
    # each floored at 16px per spec. Only these six sizes are used anywhere.
    # Fallbacks to the pre-existing named Helv_* fonts are set first so every
    # L(font_*) key is always valid even if the "font" command is unavailable.
    #
    # IMPORTANT (v0.3.2/v0.3.3): every one of these fonts -- including
    # font_button -- is scaled by `font_scale` (real physical screen), NOT
    # `scale` (virtual coordinate space). v0.3.1's bug was using `scale` for
    # these. v0.3.2 fixed the five text fonts but left button labels on a
    # `dui aspect set -type dbutton_label {font_size ...}` call using `scale`
    # -- that aspect key turned out not to be honored by the framework on
    # the tablet (buttons still rendered at a small skin-default size), which
    # is a different, second code path from the raw-Tk-font one card text
    # uses. Fix: font_button is now a real Tk font object on `font_scale`,
    # same basis as font_primary, passed directly via `-label_font` on every
    # `dui add dbutton` call (a per-instance override confirmed to work in
    # plugins/visualizer_upload/plugin.tcl:467,505-507) instead of relying on
    # the aspect style's font_size key.
    set L(font_title) Helv_20_bold
    set L(font_section) Helv_18_bold
    set L(font_primary) Helv_10_bold
    set L(font_body) Helv_9
    set L(font_caption) Helv_8
    set L(font_button) Helv_10_bold

    catch {
        foreach {name ref bold} {title 40 1 section 24 1 primary 22 1 body 19 0 caption 16 0 button 20 1} {
            set px [expr {int(max(16, round($ref * $font_scale)))}]
            set fname "SHE_$name"
            set weight [expr {$bold ? "bold" : "normal"}]
            if {[lsearch -exact [font names] $fname] >= 0} {
                font configure $fname -size [expr {-$px}] -weight $weight
            } else {
                font create $fname -family Helvetica -size [expr {-$px}] -weight $weight
            }
            set L(font_$name) $fname
        }
    }

    # v0.8.0: icon font for the theme toggle's sun/moon face (the app's
    # own FA6 Pro file, dui's loader; text fallback when unavailable).
    # v0.8.4: line height of the caption font in VIRTUAL units, for stacking
    # a text line above another item (the Trash / Source Inspector column
    # header sat 32 virtual px above row 0 while the caption line is 38
    # tall: tablet-found overlap, verify.sh pass 02). `font metrics` answers
    # in physical px; the y axis maps physical -> virtual by sh/psh. The
    # fallback is 1.25 x the 16 px reference when no font system exists.
    set L(caption_h) [expr {int(ceil(16 * 1.25 * $scale))}]
    catch {
        set lh [font metrics $L(font_caption) -linespace]
        if {$lh > 0} { set L(caption_h) [expr {int(ceil($lh * double($sh) / $psh))}] }
    }

    set L(have_icons) 0
    set L(font_icon) $L(font_button)
    catch {
        set fam [dui::font::add_or_get_familyname "Font Awesome 6 Pro-Regular-400.otf"]
        if {$fam ne ""} {
            set px [expr {int(max(16, round(26 * $font_scale)))}]
            if {[lsearch -exact [font names] SHE_icon] >= 0} {
                font configure SHE_icon -family $fam -size [expr {-$px}]
            } else {
                font create SHE_icon -family $fam -size [expr {-$px}]
            }
            set L(font_icon) SHE_icon
            set L(have_icons) 1
        }
    }

    # Shared button aspect style: same corner radius everywhere (B4). Label
    # font is set directly per-instance via -label_font (see note above), so
    # no dbutton_label font aspect is defined. Per-instance calls still pass
    # their own -bwidth/-bheight/-label.
    #
    # -theme default is REQUIRED (BeanScanner v0.1.2 lesson, reconfirmed for
    # this plugin in v0.5.4): "dui aspect set" writes into the *current*
    # theme, and by the time this plugin loads, Lumen's DYE integration has
    # switched the current theme to DYE_Lumen (skins/Lumen/skin.tcl:1831,
    # confirmed in the app log: GrindAdvisor loads before that switch, this
    # plugin after it). Aspect lookup falls back from a named theme to
    # default, never the other way, so a style registered into DYE_Lumen is
    # invisible to these -theme default pages -- no button shape was drawn
    # at all. Explicit fills make the style independent of load order.
    catch {
        dui aspect set -theme default -type dbutton -style she_btn [list \
            shape round radius $L(btn_radius) \
            fill $L(btn_fill) disabledfill $L(btn_disabled_fill)]
        dui aspect set -theme default -type dbutton_label -style she_btn [list \
            fill $L(btn_label_fill) disabledfill $L(btn_label_disabled)]
    }
    # v0.16.0: the Bags view's tokens.
    _init_bag_layout
}

# Full-page background, drawn as the first item of every page so the
# plugin's contrast never depends on which skin theme happens to be active
# (fpdialog pages otherwise show whatever page or canvas lies beneath them
# -- under Lumen's dark mode that is near-black, which made this plugin's
# dark-on-light design unreadable). Copied verbatim from BeanScanner's
# proven _page_bg.
proc ::plugins::ShotHistoryEditor::_page_bg {page} {
    variable L
    variable bg_pages
    dui add canvas_item rect $page 0 0 $L(screen_w) $L(screen_h) \
        -fill $L(page_bg) -outline $L(page_bg) -tags page_bg
    # v0.15.1: registered for _retheme_all (review: a helper-built page kept
    # a light background in dark mode).
    if {$page ni $bg_pages} { lappend bg_pages $page }
}

# v0.13.1: ONE pager for every paged page (owner decision 2026-09-30, the
# same standard in MaintenanceTracker and GrindAdvisor): bottom-right of the
# bottom bar, Next's right edge on right_x, Prev an sm gap to its left,
# arrow + word labels, both buttons always visible. The bar's other buttons
# fill from the left (Done first).
proc ::plugins::ShotHistoryEditor::_add_pager {page prev_tag next_tag prev_cmd next_cmd} {
    variable L
    variable pager_tags
    # v0.15.1: registered for _retheme_all, like _add_back.
    set pager_tags($page) [list $prev_tag $next_tag]
    set bw $L(btn_w_std)
    set next_x1 [expr {$L(right_x) - $bw}]
    set prev_x1 [expr {$next_x1 - $L(sm) - $bw}]
    dui add dbutton $page $prev_x1 $L(bar_y0) [expr {$prev_x1 + $bw}] $L(bar_y1) -tags $prev_tag \
        -label [translate "[_u 0x25c0] Prev"] -command $prev_cmd \
        -label_font $L(font_button) -style she_btn
    dui add dbutton $page $next_x1 $L(bar_y0) $L(right_x) $L(bar_y1) -tags $next_tag \
        -label [translate "Next [_u 0x25b6]"] -command $next_cmd \
        -label_font $L(font_button) -style she_btn
}

# Disables the unavailable pager button instead of hiding it, so nothing on
# the bar moves between pages. The WILDCARD tag reaches the shape, the label
# and the tap rect, and dui restyles them with the style's disabled fills.
# v0.15.1 (F13, review fold-in): through dui's enable_or_disable, which
# leaves a hidden page alone. The raw -state config also reached a page a
# late show hook refreshed after the user had left it, drawing Prev / Next
# over the next page.
proc ::plugins::ShotHistoryEditor::_set_pager_state {page prev_tag next_tag has_prev has_next} {
    catch { dui item enable_or_disable [expr {$has_prev ? 1 : 0}] $page ${prev_tag}* }
    catch { dui item enable_or_disable [expr {$has_next ? 1 : 0}] $page ${next_tag}* }
}

# v0.15.1 (F13): every sub-page's header -- the main page's 40 px title
# (font_title at header_title_y) and one caption-size subtitle line under
# it (header_subtitle_y), both centred; tags page_title and subtitle. The
# page and its title role (text_hi, or danger on the confirm pages) are
# registered, so _retheme_all repaints them with no list edit. Pass plain
# English: the helper translates.
proc ::plugins::ShotHistoryEditor::_subpage_header {page title subtitle {role text_hi}} {
    variable L
    variable header_roles
    set cx [expr {($L(left_x) + $L(right_x)) / 2}]
    dui add dtext $page $cx $L(header_title_y) -tags page_title -text [translate $title] \
        -font $L(font_title) -width $L(content_w) -fill $L($role) -anchor center -justify center
    dui add dtext $page $cx $L(header_subtitle_y) -tags subtitle -text [translate $subtitle] \
        -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor center -justify center
    set header_roles($page) $role
}

# v0.15.1 (F13): a sub-page's one way out -- Back, bottom-left at left_x,
# standard width, tag back; command is the page's return (_return_to_page
# to its parent, or the edit flow's own). The page is registered for
# _retheme_all. Returns the x where the next bar button goes, sm right of it.
proc ::plugins::ShotHistoryEditor::_add_back {page command} {
    variable L
    variable back_pages
    set x1 [expr {$L(left_x) + $L(btn_w_std)}]
    dui add dbutton $page $L(left_x) $L(bar_y0) $x1 $L(bar_y1) -tags back \
        -label [translate "Back"] -command $command \
        -label_font $L(font_button) -style she_btn
    if {$page ni $back_pages} { lappend back_pages $page }
    return [expr {$x1 + $L(sm)}]
}

# v0.15.2 (F18): a titled section card -- the house card (card_bg, card
# outline, card radius) with a 24 px section title in its top band, as on
# GrindAdvisor's Advanced. Tags <tag>_bg and <tag>_title (_retheme_all
# repaints the two Advanced cards). Returns the y of the first content row.
proc ::plugins::ShotHistoryEditor::_sec_card {page tag x y w h title} {
    variable L
    rounded_rect $page $x $y [expr {$x + $w}] [expr {$y + $h}] $L(card_radius) \
        -fill $L(card_bg) -outline $L(card_outline) -width 2 -tags ${tag}_bg
    dui add dtext $page [expr {$x + $L(sec_pad)}] [expr {$y + $L(sec_pad) + $L(sec_title_h) / 2}] \
        -tags ${tag}_title -text [translate $title] -font $L(font_section) \
        -width [expr {$w - 2 * $L(sec_pad)}] -fill $L(text_hi) -anchor w -justify left
    return [expr {$y + $L(sec_pad) + $L(sec_title_h) + $L(md)}]
}

# Draws a rounded-rectangle card backdrop through the dui canvas_item wrapper
# using the standard Tk smoothed-polygon technique (no rounded-rect primitive
# was found anywhere in this workspace's plugins, so this is the new helper
# requested by the spec; reused by every card/panel background in this file).
proc ::plugins::ShotHistoryEditor::rounded_rect {page x1 y1 x2 y2 radius args} {
    set r $radius
    if {$r * 2 > ($x2 - $x1)} { set r [expr {($x2 - $x1) / 2}] }
    if {$r * 2 > ($y2 - $y1)} { set r [expr {($y2 - $y1) / 2}] }
    set pts [list \
        [expr {$x1 + $r}] $y1 \
        [expr {$x2 - $r}] $y1 \
        $x2 $y1 \
        $x2 [expr {$y1 + $r}] \
        $x2 [expr {$y2 - $r}] \
        $x2 $y2 \
        [expr {$x2 - $r}] $y2 \
        [expr {$x1 + $r}] $y2 \
        $x1 $y2 \
        $x1 [expr {$y2 - $r}] \
        $x1 [expr {$y1 + $r}] \
        $x1 $y1]
    return [uplevel #0 [list dui add canvas_item polygon $page {*}$pts -smooth 1 {*}$args]]
}

proc ::plugins::ShotHistoryEditor::preload_pages {} {
    package require de1_dui 1.0
    catch { package require sqlite3 }
    catch { package require json }
    # v0.8.0: the theme choice is this plugin's first persisted setting.
    catch { plugins load_settings ShotHistoryEditor }
    variable settings
    if {![info exists settings(theme)] || $settings(theme) ni {light dark}} {
        set settings(theme) light
    }
    _init_layout

    dui page add ShotHistoryEditor_settings -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_advanced -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_delete_review -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_delete_confirm -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_delete_result -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_trash -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_recent -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_detail -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_edit_preview -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_edit_confirm -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_edit_result -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_diagnostics -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_help -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_reconcile -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_empty_preview -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_purge_confirm -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_purge_result -namespace true -theme default -type fpdialog
    # v0.21.0: the history_trash move page; v0.22.0: its confirmation and result.
    dui page add ShotHistoryEditor_migrate_preview -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_migrate_confirm -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_migrate_result -namespace true -theme default -type fpdialog
    # v0.16.0: the Bags tab and its (preview-only) editor.
    dui page add ShotHistoryEditor_bags -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_bag_edit -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_bag_review -namespace true -theme default -type fpdialog
    # v0.17.0: the bag Save -- typed confirmation, then the result.
    dui page add ShotHistoryEditor_bag_confirm -namespace true -theme default -type fpdialog
    dui page add ShotHistoryEditor_bag_result -namespace true -theme default -type fpdialog
    return ShotHistoryEditor_settings
}

proc ::plugins::ShotHistoryEditor::open_page {page} {
    foreach cmd [list \
        [list dui page open_dialog $page] \
        [list dui page load $page] \
        [list dui page show $page]] {
        if {![catch { uplevel #0 $cmd }]} { return 1 }
    }
    catch { msg "ShotHistoryEditor: could not open page $page" }
    return 0
}

# ---------------------------------------------------------------------------
# v0.5.2 -- safe Done/Back navigation against the confirmed de1app-core
# page_stack bug (root cause verified for GrindAdvisor v1.8.8, from
# de1app-core/dui.tcl; see GrindAdvisor/CHANGELOG.md's "v1.8.8" entry for
# the full trace). `::dui::page::load`'s "Handle page stack" block resets
# `page_stack` to a single entry every time a page of type "default" is
# shown -- e.g. the flow-monitor page shown while a flush/rinse/steam/clean/
# etc. runs -- even while an `fpdialog` page (every page in this plugin) is
# current, because the framework's "only one dialog page visible" guard
# only checks type "dialog", not "fpdialog". When this plugin's page is
# re-shown afterwards, it gets pushed onto that freshly-wiped stack, so
# `dui page close_dialog` (which navigates to "previous" in page_stack)
# lands on the flow page instead of this plugin's real parent page -- not a
# bug specific to GrindAdvisor, but how this DE1app build's page_stack
# behaves for any fpdialog left open across a flush/rinse/steam
# interruption, with no self-healing. This class of bug is different from
# (and layered on top of) the v0.4.1/v0.5.1 multi-level-stack bugs already
# fixed above: those were about `close_dialog` only popping one level of a
# plugin-internal flow; this one is about `close_dialog` trusting a stack
# that an *external* page change silently corrupted.
#
# Fix: two complementary mechanisms, split by destination (v0.5.3 -- the
# v0.5.2 version of this fix used `dui page load` for BOTH cases, which
# broke multi-level returns; see _return_to_page's note below for the core
# truncation bug that makes direct load unsafe for stacked ancestors).
# - Exiting the plugin (Settings Done): _navigate_done with the outside
#   page captured by _capture_return_page. Loading a default-type page
#   resets the core's page_stack entirely (dui.tcl ~line 6464), so this
#   exit is clean regardless of what a flush interruption did to the stack.
# - Returning to an ancestor within this plugin's own dialog stack:
#   _return_to_page, which unwinds one close_dialog at a time (the only
#   stack shape this core truncates correctly) and falls back to
#   _navigate_done's validated load only if the stack is corrupted.
proc ::plugins::ShotHistoryEditor::_is_transient_name {name} {
    if {$name eq ""} { return 1 }
    return [regexp -nocase {espresso|steam|water|rinse|flush|clean|cleaning|descale|purge} $name]
}

# Called from the Settings page's own show{page_to_hide page_to_show} (the
# only page in this plugin whose Done target is dynamic rather than a
# hardcoded ancestor name). page_to_hide is skipped whenever it looks like a
# flow/monitor page name, so a flush/rinse/steam interruption's re-show can
# never clobber the last legitimate return target.
#
# v0.5.3 bugfix: also skip this plugin's OWN pages. Returning to Settings
# from a sub-flow (e.g. Cancel on Delete Step 2) re-shows Settings with
# page_to_hide = that sub-page; v0.5.2 captured it, so the next Settings
# Done loaded the sub-page again instead of leaving the plugin (tablet-
# reproduced: Done ping-ponged back to the Step 2 confirm page). Only a
# page that is neither ours nor a flow screen -- i.e. the genuine outside
# page the plugin was opened from -- is a valid exit target.
proc ::plugins::ShotHistoryEditor::_capture_return_page {page_to_hide} {
    variable _settings_return_page
    if {$page_to_hide eq ""} { return }
    if {[string match "ShotHistoryEditor_*" $page_to_hide]} { return }
    if {![_is_transient_name $page_to_hide]} {
        set _settings_return_page $page_to_hide
    }
}

proc ::plugins::ShotHistoryEditor::_navigate_done {target} {
    set ok 0
    if {$target ne "" && ![_is_transient_name $target]} {
        catch { set ok [dui page exists $target] }
    }
    # v0.8.3: the close_dialog fallbacks used to be bare catches; a failed
    # exit is now logged (CLAUDE.md: navigation errors must be visible).
    if {$ok} {
        if {[catch { uplevel #0 [list dui page load $target] } err]} {
            msg -ERROR "ShotHistoryEditor: navigating to $target failed: $err"
            if {[catch { dui page close_dialog } err2]} {
                msg -ERROR "ShotHistoryEditor: close_dialog fallback failed: $err2"
            }
        }
    } else {
        if {[catch { dui page close_dialog } err]} {
            msg -ERROR "ShotHistoryEditor: close_dialog failed (no valid return page '$target'): $err"
        }
    }
}

# v0.5.3 bugfix -- returns to an ancestor page of this plugin's own dialog
# stack. v0.5.2 did this with a single `dui page load $target`, trusting the
# core to truncate the stale stack entries above $target. Reading the actual
# truncation code (de1app-core/dui.tcl, "Handle page stack" block, ~line
# 6470) shows why that failed on the tablet: it truncates with
#   dict unset page_stack {*}[lrange [dict keys $page_stack] idx+1 end]
# and multi-argument `dict unset` treats the extra keys as a NESTED KEY
# PATH, not a list of top-level keys (verified empirically with tclsh
# against a simulated stack). So truncating exactly 1 stale page works,
# 2 stale pages silently does nothing (stale entries stay stacked), and 3+
# throws, aborting the whole load -- which is exactly the tablet behavior:
# Done on Delete Result (3 stale pages) errored into the close_dialog
# fallback and landed on Step 2; Cancel on Step 2 (2 stale pages) looked
# fine but left review+confirm buried in the stack to resurface later.
#
# Fix: unwind ONE level at a time with `dui page close_dialog` -- each step
# is the 1-stale-page case the core truncates correctly -- until the target
# is current. Bounded, with a progress check, and it stops immediately if
# the current page is no longer one of ours (e.g. a flush interruption
# corrupted the stack), falling back to _navigate_done's validated direct
# load in that case. Failures are logged via msg, never swallowed silently.
proc ::plugins::ShotHistoryEditor::_return_to_page {target} {
    set prev ""
    for {set i 0} {$i < 10} {incr i} {
        set cur ""
        catch { set cur [dui page current] }
        if {$cur eq $target} { return }
        if {![string match "ShotHistoryEditor_*" $cur]} { break }
        if {$cur eq $prev} { break }
        set prev $cur
        if {[catch { dui page close_dialog } err]} {
            catch { msg "ShotHistoryEditor: close_dialog failed returning to $target: $err" }
            break
        }
    }
    set cur ""
    catch { set cur [dui page current] }
    if {$cur ne $target} {
        _navigate_done $target
    }
}

proc ::plugins::ShotHistoryEditor::_homedir {} {
    if {[llength [info commands homedir]]} {
        return [homedir]
    }
    variable plugin_dir
    return [file dirname [file dirname $plugin_dir]]
}

proc ::plugins::ShotHistoryEditor::_plugins_dir {} {
    if {[llength [info commands plugin_directory]]} {
        set pd [plugin_directory]
        if {[file pathtype $pd] eq "absolute"} { return $pd }
        return [file join [_homedir] $pd]
    }
    variable plugin_dir
    return [file dirname $plugin_dir]
}

namespace eval ::plugins::ShotHistoryEditor {
    # Writable user-data root. de1app main (since e14b7d0, 2026-06-23) has
    # data_directory; older cores (stable v1.46.1, the tablet) have only homedir.
    # Both return the same folder on Android/macOS today. No catch, never throws.
    proc _data_root {} {
        if {[llength [info commands ::data_directory]]} { return [::data_directory] }
        if {[llength [info commands ::homedir]]}        { return [::homedir] }
        variable plugin_dir    ;# headless tests only: <root>/plugins/<Name>
        return [file dirname [file dirname $plugin_dir]]
    }
}

# v0.20.0: SDB's own answer first (it honours a custom settings(db_path); SDB
# 1.26 on the tablet and upstream both have db_path, still homedir-rooted),
# else the two places SDB keeps it by default.
proc ::plugins::ShotHistoryEditor::sdb_path {} {
    if {[llength [info commands ::plugins::SDB::db_path]] &&
        [info exists ::plugins::SDB::settings(db_path)] &&
        [string trim $::plugins::SDB::settings(db_path)] ne ""} {
        return [::plugins::SDB::db_path]
    }
    set candidates [list \
        [file join [_plugins_dir] SDB shots.db] \
        [file join [_homedir] plugins SDB shots.db]]
    foreach p $candidates {
        if {[file isfile $p]} { return $p }
    }
    return [lindex $candidates 0]
}

# v0.20.0: the app's history folders live under its data root (John, de1app
# PR #373). SHE reads and writes both there: edits, moves, mtime stamps.
proc ::plugins::ShotHistoryEditor::history_path {} {
    return [file join [_data_root] history]
}

proc ::plugins::ShotHistoryEditor::history_v2_path {} {
    return [file join [_data_root] history_v2]
}

# ---------------------------------------------------------------------------
# v0.22.0 -- where SHE's own files live (John, de1app PR #373: users' trash,
# backups and logs belong under the app's data folder, not the plugin's code
# folder). SHE keeps 8 items: trash/, backups/ and six .txt manifests and
# logs. They live in <data root>/history_trash/ once the one-time move has
# run (Advanced > Move trash and logs..., perform_she_move) and on a fresh
# install; an install that has not moved yet keeps them in its plugin folder
# (CLAUDE.md purge exception and one-time-move rule, 2026-10-21). trash/
# holds nothing but batch folders: Tidy and Empty trash remove every empty
# folder directly under it. (v0.21.0 previewed the move read-only; measured
# on the tablet 2026-10-21 with adb: a folder renamed from
# plugins/ShotHistoryEditor/ to the de1plus root keeps every inode and the
# device -- a true rename, never a copy, on this storage.)
# ---------------------------------------------------------------------------

# The plugin folder SHE's files lived in before the move: the one place that
# builds it, and never the new root (so a moved install can still see a
# leftover there as a conflict).
proc ::plugins::ShotHistoryEditor::_she_legacy_dir {} {
    return [file join [_plugins_dir] ShotHistoryEditor]
}

# The folder SHE reads and writes its own files in NOW (see _she_layout).
proc ::plugins::ShotHistoryEditor::_she_data_dir {} {
    return [dict get [_she_layout] root]
}

# One item's path. Only while a move is unfinished can items sit in two
# folders: then it is wherever the item is (the staging folder first).
proc ::plugins::ShotHistoryEditor::_she_entry_path {name} {
    set lay [_she_layout]
    set p [file join [dict get $lay root] $name]
    if {[dict get $lay state] eq "unfinished" && ![file exists $p] && [dict get $lay from] ne ""} {
        set q [file join [dict get $lay from] $name]
        if {[file exists $q]} { return $q }
    }
    return $p
}

# "" when SHE may write its own files, else why not. Checked by every write
# path before it touches anything (delete, restore, edit, bag save, Empty
# trash, Tidy, Unhide); the move itself has its own checks.
proc ::plugins::ShotHistoryEditor::_she_write_blocker {} {
    set lay [_she_layout]
    switch -- [dict get $lay state] {
        unfinished {
            return [translate "the move of the trash to history_trash/ is unfinished; finish it under Advanced > Move trash and logs..."]
        }
        conflict {
            return [translate "the plugin's trash, backups and logs are in more than one folder (see Diagnostics); nothing is written until only one holds them"]
        }
    }
    return ""
}

# Everything SHE keeps in its folder: two folders and six text files. The
# move renames exactly these; plugin code, docs and the app's settings.tdb
# stay.
proc ::plugins::ShotHistoryEditor::_she_entries {} {
    return {trash backups trash_manifest.txt delete_log.txt purge_log.txt
            reconcile_manifest.txt edit_manifest.txt edit_log.txt}
}

proc ::plugins::ShotHistoryEditor::_she_new_root {} {
    return [file join [_data_root] history_trash]
}

proc ::plugins::ShotHistoryEditor::_she_staging_root {} {
    return [file join [_data_root] history_trash.moving]
}

# The folders SHE's files can be in today, in the order a move looks: the
# data-root mirror of the plugin folder (where the app keeps plugin
# settings, and where they would be after a code/data split), then the
# plugin folder itself. On every platform today both are one folder.
proc ::plugins::ShotHistoryEditor::_she_legacy_roots {} {
    set pd plugins
    if {[llength [info commands ::plugin_directory]]} { set pd [::plugin_directory] }
    set cands {}
    if {[file pathtype $pd] ne "absolute"} { lappend cands [file join [_data_root] $pd ShotHistoryEditor] }
    lappend cands [_she_legacy_dir]
    set out {} ; set seen {}
    foreach c $cands {
        set n [file normalize $c]
        if {$n ni $seen} { lappend seen $n ; lappend out $c }
    }
    return $out
}

proc ::plugins::ShotHistoryEditor::_she_entries_in {root} {
    set found {}
    foreach e [_she_entries] {
        if {[file exists [file join $root $e]]} { lappend found $e }
    }
    return $found
}

# Where SHE's files are, read-only (no cache: a handful of stats, and every
# write path sees the disk as it is). state:
#   legacy      one plugin folder holds them (an install that has not moved)
#   fresh       none anywhere (a new install starts in history_trash/)
#   moved       only history_trash/ holds them
#   unfinished  history_trash.moving holds some (a move that stopped)
#   conflict    more than one folder holds them
# root: the folder SHE uses now. from: the one legacy folder holding items,
# else "". An EMPTY history_trash.moving (left by a rolled-back move) is
# not a state: the next move reuses it.
proc ::plugins::ShotHistoryEditor::_she_layout {} {
    set holders {}
    foreach r [_she_legacy_roots] {
        if {[llength [_she_entries_in $r]]} { lappend holders $r }
    }
    set new [_she_new_root]
    set staging [_she_staging_root]
    set new_entries {}
    if {[file isdirectory $new]} { set new_entries [_she_entries_in $new] }
    set staging_entries {}
    if {[file isdirectory $staging]} { set staging_entries [_she_entries_in $staging] }
    if {[llength $staging_entries]} {
        set state unfinished
        set root $staging
    } elseif {[llength $holders] > 1 || ([llength $holders] == 1 && [llength $new_entries])} {
        set state conflict
        set root [_pick [llength $new_entries] $new [lindex $holders 0]]
    } elseif {[llength $holders] == 1} {
        set state legacy
        set root [lindex $holders 0]
    } elseif {[llength $new_entries]} {
        set state moved
        set root $new
    } else {
        set state fresh
        set root $new
    }
    set from ""
    if {[llength $holders] == 1} { set from [lindex $holders 0] }
    return [dict create state $state root $root from $from holders $holders new $new \
        new_exists [file exists $new] new_entries $new_entries staging $staging \
        staging_exists [file exists $staging] staging_entries $staging_entries]
}

# How the move rewrites the trash manifest, line by line in file order (pure,
# no disk access). A ts|orig|trash|batch line whose trash path is strictly
# inside one of old_trashes as <batch>/<file> gets the same <batch>/<file>
# under new_trash; a line already there (a move finished after a crash) is
# kept byte for byte; anything else -- another folder, another depth, a line
# that is not four fields -- is unmapped, and the move refuses while any
# is. ts, orig and batch never change; no line is dropped or added.
proc ::plugins::ShotHistoryEditor::_migrate_manifest_plan {lines old_trashes new_trash} {
    set new_root [file normalize $new_trash]
    set prefixes {}
    foreach o $old_trashes { lappend prefixes "[file normalize $o]/" change }
    lappend prefixes "$new_root/" keep
    set out {} ; set unmapped {} ; set changed 0 ; set kept 0
    foreach line $lines {
        set parts [split $line "|"]
        if {[llength $parts] != 4} { lappend unmapped $line ; continue }
        lassign $parts ts orig trash batch
        set t [file normalize $trash]
        set mode ""
        foreach {prefix m} $prefixes {
            if {[string first $prefix $t] == 0} {
                set rel [file split [string range $t [string length $prefix] end]]
                if {[llength $rel] == 2} { set mode $m }
                break
            }
        }
        switch -- $mode {
            change {
                lappend out "$ts|$orig|[file join $new_root {*}$rel]|$batch"
                incr changed
            }
            keep {
                lappend out $line
                incr kept
            }
            default { lappend unmapped $line }
        }
    }
    return [dict create lines $out changed $changed kept $kept unmapped $unmapped]
}

# Files, bytes, folders and empty folders under dir (read-only; a folder
# that cannot be listed is counted, not entered). v0.22.0: names are
# de-duplicated -- on Windows `*` also matches dot-files, so `* .*` listed
# them twice (the tablet's `*` skips them).
proc ::plugins::ShotHistoryEditor::_tree_stats {dir} {
    set files 0 ; set bytes 0 ; set dirs 0 ; set empty 0
    if {![file isdirectory $dir] || ![file readable $dir]} {
        return [dict create files 0 bytes 0 dirs 0 empty_dirs 0]
    }
    set stack [list $dir]
    while {[llength $stack]} {
        set d [lindex $stack end]
        set stack [lrange $stack 0 end-1]
        set kids [lsort -unique [lsearch -all -inline -not -regexp [glob -nocomplain -directory $d -tails * .*] {^\.\.?$}]]
        if {$d ne $dir && [llength $kids] == 0} { incr empty }
        foreach k $kids {
            set p [file join $d $k]
            if {[file isdirectory $p]} {
                incr dirs
                if {[file readable $p]} { lappend stack $p }
            } elseif {[file isfile $p]} {
                incr files
                incr bytes [file size $p]
            }
        }
    }
    return [dict create files $files bytes $bytes dirs $dirs empty_dirs $empty]
}

proc ::plugins::ShotHistoryEditor::_line_count {path} {
    if {![file isfile $path] || ![file readable $path]} { return "" }
    set n 0
    set fh [open $path r]
    while {[gets $fh line] >= 0} { if {[string trim $line] ne ""} { incr n } }
    close $fh
    return $n
}

# The storage device a path is on ("" when it does not exist).
proc ::plugins::ShotHistoryEditor::_she_dev {path} {
    if {![file exists $path]} { return "" }
    file stat $path st
    return $st(dev)
}

# The move's own order: folders first, delete_log.txt last.
proc ::plugins::ShotHistoryEditor::_she_move_order {names} {
    set out {}
    foreach e {trash backups trash_manifest.txt reconcile_manifest.txt edit_manifest.txt
               edit_log.txt purge_log.txt delete_log.txt} {
        if {$e in $names} { lappend out $e }
    }
    return $out
}

# Everything the move would do and every reason it would refuse, read-only.
# Used by the Move page, its confirmation and perform_she_move itself, so
# what is shown is what runs. can: 1 when nothing refuses.
proc ::plugins::ShotHistoryEditor::_she_move_plan {} {
    set lay [_she_layout]
    set state [dict get $lay state]
    set src [dict get $lay from]
    set new [dict get $lay new]
    set staging [dict get $lay staging]
    set staged [dict get $lay staging_entries]
    set to_move {}
    if {$src ne ""} { set to_move [_she_move_order [_she_entries_in $src]] }
    set all [_she_move_order [lsort -unique [concat $to_move $staged]]]
    # The trash manifest, wherever it is now, and how its lines would map.
    set mf ""
    foreach r [list $staging $src] {
        if {$r ne "" && [file isfile [file join $r trash_manifest.txt]]} { set mf [file join $r trash_manifest.txt] ; break }
    }
    set lines {}
    set read_err ""
    if {$mf ne ""} {
        set rd [_manifest_read $mf 1]
        set lines [dict get $rd lines]
        set read_err [dict get $rd err]
    }
    set olds {}
    if {$src ne ""} {
        lappend olds [file join $src trash]
    } else {
        foreach r [_she_legacy_roots] { lappend olds [file join $r trash] }
    }
    set mplan [_migrate_manifest_plan $lines $olds [file join $new trash]]
    set unmapped [llength [dict get $mplan unmapped]]
    set overlap {}
    foreach e $to_move { if {$e in $staged} { lappend overlap $e } }
    # One device, so every step is a rename (CLAUDE.md: never copy-then-delete).
    set root [_data_root]
    set rdev [_she_dev $root]
    set same_dev 1
    set paths {}
    if {$src ne ""} { lappend paths $src }
    foreach e $to_move { lappend paths [file join $src $e] }
    if {[file exists $staging]} { lappend paths $staging }
    foreach p $paths { if {[_she_dev $p] ne $rdev} { set same_dev 0 } }
    set unwritable {}
    foreach p [concat [list $root] [lrange $paths 0 0]] { if {![file writable $p]} { lappend unwritable $p } }
    if {[file exists $staging] && ![file writable $staging]} { lappend unwritable $staging }
    set busy [_machine_busy]
    set checks [list \
        [file exists $new] "history_trash/ does not exist yet" "history_trash/ already exists" \
        [expr {[llength $overlap] > 0}] "no item is in two places" "[join $overlap {, }] in both the plugin folder and history_trash.moving" \
        [expr {$state eq "conflict"}] "SHE files are in one place" "more than one folder holds SHE files" \
        [expr {$read_err ne ""}] "the trash manifest reads" "the trash manifest cannot be read ($read_err)" \
        [expr {$unmapped > 0}] "every trash manifest line can be rewritten" "$unmapped trash manifest line(s) cannot be rewritten (another folder, another depth, or not ts|orig|trash|batch)" \
        [expr {!$same_dev}] "one storage device, so each step is a rename" "the folders are on different storage devices: the move never copies" \
        [expr {[llength $unwritable] > 0}] "the folders can be written" "cannot be written: [join $unwritable {, }]" \
        [expr {$busy ne ""}] "the machine is idle" "the machine is busy ($busy)" \
        [_sdb_busy] "SDB is not syncing" "SDB is syncing"]
    set refusals {}
    switch -- $state {
        fresh { lappend refusals [translate "there is nothing to move"] }
        moved { lappend refusals [translate "already moved"] }
    }
    foreach {bad ok_text bad_text} $checks { if {$bad} { lappend refusals $bad_text } }
    return [dict create lay $lay state $state src $src new $new staging $staging staged $staged \
        to_move $to_move all $all count [llength $all] manifest $mf lines $lines olds $olds mplan $mplan \
        checks $checks refusals $refusals can [expr {[llength $refusals] == 0}]]
}

# What the confirmation is typed for; the move refuses if it changed.
proc ::plugins::ShotHistoryEditor::_she_move_snap {plan} {
    return [list [dict get $plan state] [dict get $plan src] [dict get $plan to_move] \
        [dict get $plan staged] [llength [dict get $plan lines]]]
}

# The Move page's text (Advanced > Move trash and logs...), read-only, from
# _she_move_plan. Lines stay short: the shared pager counts lines, not
# wrapped rows.
proc ::plugins::ShotHistoryEditor::migrate_preview_text {} {
    set plan [_she_move_plan]
    set lay [dict get $plan lay]
    set state [dict get $plan state]
    set src [dict get $plan src]
    set new [dict get $plan new]
    switch -- $state {
        legacy     { set from $src }
        unfinished { set from "[dict get $plan staging] (unfinished)[_pick [expr {$src ne {}}] " and $src" {}]" }
        moved      { set from "nothing: already moved" }
        conflict   { set from "more than one folder (below)" }
        default    { set from "nothing: no SHE files yet" }
    }
    set lines [list \
        "Nothing moves until you tap Move now... and type the number on the next page. Each item is renamed" \
        "once into history_trash/; nothing is deleted (only the manifest is copied); history/ and history_v2/ stay." \
        "" \
        "From: $from" \
        "To: $new" \
        ""]
    switch -- $state {
        fresh { lappend lines "SHE has no trash, backups or logs yet: a new install keeps them in history_trash/ from the start." }
        moved { lappend lines "Already moved: [join [dict get $lay new_entries] {, }] are in history_trash/. SHE uses that folder." }
        unfinished {
            lappend lines "A move stopped part way: [join [dict get $plan staged] {, }] wait in history_trash.moving."
            lappend lines "Nothing can be deleted, restored or saved until it is finished: tap Finish move..."
        }
        conflict {
            lappend lines "More than one folder holds SHE files, so nothing is written until only one does:"
            foreach h [dict get $lay holders] { lappend lines "  $h: [join [_she_entries_in $h] {, }]" }
            if {[llength [dict get $lay new_entries]]} { lappend lines "  $new: [join [dict get $lay new_entries] {, }]" }
        }
    }
    if {$state in {legacy unfinished}} {
        set base [_pick [expr {$src ne {}}] $src [dict get $plan staging]]
        set tstats [_tree_stats [file join $base trash]]
        set bstats [_tree_stats [file join $base backups]]
        set mlines [dict get $plan lines]
        set batches [lsort -unique [lmap l $mlines { lindex [split $l |] 3 }]]
        set mp [dict get $plan mplan]
        set unmapped [llength [dict get $mp unmapped]]
        lappend lines "What moves ([dict get $plan count] of 8 items here):"
        lappend lines "  trash/: [llength $batches] batch(es), [dict get $tstats files] file(s), [_fmt_bytes [dict get $tstats bytes]]; [dict get $tstats dirs] folder(s), [dict get $tstats empty_dirs] of them empty"
        lappend lines "  backups/: [dict get $bstats dirs] folder(s), [dict get $bstats files] file(s), [_fmt_bytes [dict get $bstats bytes]]"
        if {[dict get $plan manifest] eq ""} {
            lappend lines "  trash_manifest.txt: not there yet"
        } elseif {$unmapped == 0} {
            lappend lines "  trash_manifest.txt: [llength $mlines] line(s); [dict get $mp changed] re-pointed to history_trash/trash/, [dict get $mp kept] already there"
        } else {
            lappend lines "  trash_manifest.txt: [llength $mlines] line(s); $unmapped cannot be rewritten, so the move refuses"
        }
        foreach {f note} {
            delete_log.txt {moved as is, plus MIGRATE lines}
            purge_log.txt {moved as is}
            reconcile_manifest.txt {moved as is}
            edit_manifest.txt {moved as is; the backup paths in it are only shown, never used}
            edit_log.txt {moved as is}
        } {
            set p [file join $base $f]
            if {![file exists $p] && $src ne "" && [file exists [file join [dict get $plan staging] $f]]} { set p [file join [dict get $plan staging] $f] }
            set c [_line_count $p]
            if {$c eq ""} {
                lappend lines "  $f: not there yet (it starts in history_trash/)"
            } else {
                lappend lines "  $f: $c line(s), $note"
            }
        }
        lappend lines "Stays in the plugin folder: its code, its docs and settings.tdb (the app keeps the theme there)."
    }
    lappend lines ""
    lappend lines "The move refuses while any of these holds (it checks them again when it runs):"
    foreach {bad ok_text bad_text} [dict get $plan checks] {
        if {$bad} { lappend lines "  WOULD REFUSE NOW: $bad_text" } else { lappend lines "  ok: $ok_text" }
    }
    lappend lines ""
    lappend lines "SHE uses [_she_data_dir] now. After the move an older SHE version would show an empty trash."
    return [join $lines "\n"]
}

# The move's audit log: delete_log.txt wherever it is now (staging first),
# else a new one in the folder that is moving.
proc ::plugins::ShotHistoryEditor::_she_move_log_path {plan} {
    set staging [dict get $plan staging]
    set src [dict get $plan src]
    foreach r [list $staging $src] {
        if {$r ne "" && [file isfile [file join $r delete_log.txt]]} { return [file join $r delete_log.txt] }
    }
    if {$src ne ""} { return [file join $src delete_log.txt] }
    return [file join $staging delete_log.txt]
}

# ---------------------------------------------------------------------------
# v0.22.0 -- the one-time move (WRITE CAPABILITY 9; CLAUDE.md one-time-move
# rule, 2026-10-21). Moves SHE's OWN 8 items from the plugin folder to
# <data root>/history_trash/ by `file rename` only, on one storage device,
# after a typed count. history/ and history_v2/ are never touched; nothing is
# copied except the trash manifest's audit copy; nothing is deleted.
#   1  MIGRATE BEGIN in delete_log.txt (write-ahead: if it cannot be written,
#      nothing moves)
#   2  file mkdir history_trash.moving (an empty one is reused)
#   3  each item: file rename <plugin folder>/<item> -> history_trash.moving/
#   4  trash_manifest.txt: file copy to trash_manifest.before_move.txt (once),
#      the re-pointed lines written to trash_manifest.txt.new, read back,
#      file rename over trash_manifest.txt (v0.23.2: not when no line is
#      left to re-point)
#   5  commit: file rename history_trash.moving -> history_trash
#   6  MIGRATE OK + one MIGRATE ITEM line per item
# A step that fails rolls back what this run did (items renamed back, the
# manifest renamed back from its copy) and logs MIGRATE FAILED. A crash in
# between leaves state "unfinished": every write is refused until the same
# page finishes the move (steps 1-6 again: roll forward only; lines already
# re-pointed are kept, so no record is lost or doubled).
# ---------------------------------------------------------------------------

# v0.23.1: when the re-pointed manifest cannot be put back from its copy,
# nothing else moves back either: the items stay in the staging folder WITH
# that manifest (state unfinished), and Finish move... completes the move --
# never a re-pointed manifest back in the plugin folder.
proc ::plugins::ShotHistoryEditor::_she_move_rollback {src staging moved manifest_done} {
    set problems {}
    set bm [file join $staging trash_manifest.before_move.txt]
    set mf [file join $staging trash_manifest.txt]
    if {$manifest_done} {
        if {[catch { file rename -force -- $bm $mf } err]} {
            msg -ERROR "ShotHistoryEditor: the move's trash_manifest.txt could not be put back from its copy: $err"
            return [list "trash_manifest.txt could not be put back from its copy ($err), so every item stays in $staging with it"]
        }
    }
    foreach e [lreverse $moved] {
        set a [file join $staging $e] ; set b [file join $src $e]
        if {[file exists $b]} { lappend problems "$e: $b exists, left in $staging" ; continue }
        if {[catch { file rename -- $a $b } err]} { lappend problems "$e: not put back: $err" }
    }
    return $problems
}

# The one place that moves SHE's files. snap: _she_move_snap of the plan the
# count was typed for. Returns ok, message, moved items, rollback problems.
proc ::plugins::ShotHistoryEditor::perform_she_move {snap} {
    set res [dict create ok 0 message "" items {} new "" problems {} log_ok 1 changed 0 kept 0 audit none]
    set plan [_she_move_plan]
    if {![dict get $plan can]} {
        dict set res message "[translate {Not moved}]: [join [dict get $plan refusals] {; }]."
        return $res
    }
    if {[_she_move_snap $plan] ne $snap} {
        dict set res message [translate "Not moved: the folders changed since the confirmation opened. Open it again."]
        return $res
    }
    set ts [clock format [clock seconds] -format {%Y%m%dT%H%M%S}]
    set src [dict get $plan src]
    set staging [dict get $plan staging]
    set new [dict get $plan new]
    dict set res new $new
    # v0.23.1: the manifest's bytes before anything moves, for the check
    # after a rollback; unreadable = nothing moves.
    set pre_mf [dict get $plan manifest]
    set pre_bytes ""
    if {$pre_mf ne "" && [catch { set pre_bytes [_read_bytes $pre_mf] } err]} {
        dict set res message "[translate {Not moved}]: [translate {the trash manifest cannot be read}] ($err)."
        return $res
    }
    # 1. write-ahead
    set blog [_she_move_log_path $plan]
    set begin "$ts MIGRATE BEGIN from=$src to=$new items=[join [dict get $plan all] ,] staged=[join [dict get $plan staged] ,] manifest_lines=[llength [dict get $plan lines]]"
    if {![_she_append $blog $begin]} {
        dict set res message "[translate {Not moved}]: [translate {the MIGRATE BEGIN line could not be written to}] $blog."
        return $res
    }
    msg -NOTICE "ShotHistoryEditor: $begin"
    # The BEGIN line may have created delete_log.txt in the plugin folder.
    set to_move {}
    if {$src ne ""} { set to_move [_she_move_order [_she_entries_in $src]] }
    set moved {}
    set manifest_done 0
    set step "" ; set item "" ; set err ""
    # 2. the staging folder
    if {![file isdirectory $staging] && [catch { file mkdir $staging } err]} {
        set step mkdir
    }
    # 3. one rename per item
    if {$step eq ""} {
        foreach e $to_move {
            set a [file join $src $e] ; set b [file join $staging $e]
            if {[file exists $b]} { set step rename ; set item $e ; set err "already in $staging" ; break }
            if {[catch { file rename -- $a $b } err]} { set step rename ; set item $e ; break }
            lappend moved $e
        }
    }
    # 4. the trash manifest, re-pointed in place
    set mf [file join $staging trash_manifest.txt]
    if {$step eq "" && [file isfile $mf]} {
        set bm [file join $staging trash_manifest.before_move.txt]
        set tmp "$mf.new"
        # v0.23.1: re-read all of it or stop -- a short read would write a
        # short manifest -- and it must be the plan's own line count.
        set rd [_manifest_read $mf 1]
        set mp [_migrate_manifest_plan [dict get $rd lines] [dict get $plan olds] [file join $new trash]]
        dict set res changed [dict get $mp changed]
        dict set res kept [dict get $mp kept]
        set seen [expr {[dict get $mp changed] + [dict get $mp kept] + [llength [dict get $mp unmapped]]}]
        set want ""
        if {[llength [dict get $mp lines]]} { set want "[join [dict get $mp lines] \n]\n" }
        # The audit copy is this run's own copy of a manifest nothing has
        # re-pointed yet (a copy left by an earlier stopped attempt may be
        # older). Once lines are re-pointed, the copy made just before that
        # is the original and is kept; writes are refused since.
        # v0.23.2: a manifest with nothing left to re-point (a Finish move
        # after the rewrite) is not written again, so a failed commit never
        # rolls a copy back over it; and when lines are re-pointed but the
        # copy is gone, the manifest as it is now becomes the copy (audit
        # "remade") instead of stopping every Finish move for good.
        set kept [dict get $mp kept]
        set have_bm [file isfile $bm]
        if {$kept == 0} { dict set res audit made } elseif {!$have_bm} { dict set res audit remade } else { dict set res audit kept }
        if {![dict get $rd ok]} {
            set step manifest-read ; set err [dict get $rd err]
        } elseif {$seen != [llength [dict get $plan lines]]} {
            set step manifest-count ; set err "it has $seen line(s), the confirmation [llength [dict get $plan lines]]"
        } elseif {[llength [dict get $mp unmapped]]} {
            set step manifest ; set err "[llength [dict get $mp unmapped]] line(s) cannot be rewritten"
        } elseif {($kept == 0 || !$have_bm) && [catch { file copy -force -- $mf $bm } err]} {
            set step manifest-copy
        } elseif {[dict get $mp changed] == 0} {
            # Nothing to re-point: the manifest stays byte for byte.
        } elseif {[catch {
            set fh [open $tmp w]
            fconfigure $fh -encoding utf-8 -translation lf
            puts -nonewline $fh $want
            close $fh
        } err]} {
            if {[info exists fh]} { catch { close $fh } }
            set step manifest-write
        } elseif {[catch { _read_bytes $tmp } got] || $got ne [encoding convertto utf-8 $want]} {
            set step manifest-check ; set err "the new manifest did not read back"
        } elseif {[catch { file rename -force -- $tmp $mf } err]} {
            set step manifest-rename
        } else {
            set manifest_done 1
        }
    }
    # 5. commit
    if {$step eq ""} {
        if {[file exists $new]} {
            set step commit ; set err "$new appeared"
        } elseif {[catch { file rename -- $staging $new } err]} {
            set step commit
        }
    }
    if {$step ne ""} {
        set problems [_she_move_rollback $src $staging $moved $manifest_done]
        # v0.23.1: "put back as it was" is checked on the disk, not assumed:
        # every item this run moved is back in the plugin folder, none is
        # left in the staging folder, and a manifest that moved this run has
        # its bytes from before the move.
        if {[llength $problems] == 0} {
            foreach e $moved {
                if {![file exists [file join $src $e]] || [file exists [file join $staging $e]]} {
                    lappend problems "$e is not back in $src"
                }
            }
            if {"trash_manifest.txt" in $moved && [llength $problems] == 0} {
                if {[catch { _read_bytes [file join $src trash_manifest.txt] } got] || $got ne $pre_bytes} {
                    lappend problems "trash_manifest.txt is not as it was before the move"
                }
            }
        }
        dict set res problems $problems
        set rb [_pick [llength $problems] "NOT fully: [join $problems {; }]" "yes"]
        # The log path without trusting the folders (a failed step may leave
        # them half way): wherever delete_log.txt is now.
        set flog ""
        foreach r [list $staging $src] {
            if {$r ne "" && $flog eq "" && [file isfile [file join $r delete_log.txt]]} { set flog [file join $r delete_log.txt] }
        }
        if {$flog eq ""} { set flog [file join [_pick [expr {$src ne {}}] $src $staging] delete_log.txt] }
        set flog_ok [_she_append $flog "$ts MIGRATE FAILED step=$step item=$item err=$err; rolled back: $rb"]
        msg -ERROR "ShotHistoryEditor: the move stopped at $step $item: $err; rolled back: $rb"
        if {[llength $problems]} {
            dict set res message "[translate {Stopped at}] $step $item: $err. [translate {Not everything is as it was}]: [join $problems {; }]."
            if {![catch { dict get [_she_layout] state } now] && $now eq "unfinished"} {
                dict append res message " [translate {The move is unfinished: tap Finish move... on the Move page.}]"
            } else {
                dict append res message " [translate {Look at the Move page before trying again.}]"
            }
        } else {
            dict set res message "[translate {Stopped at}] $step $item: $err. [translate {Everything was put back as it was (checked on the disk); nothing moved.}]"
        }
        if {!$flog_ok} {
            dict append res message " [translate {The MIGRATE FAILED line could not be written to}] $flog; [translate {see the app log.}]"
        }
        return $res
    }
    # 6. audit
    set lp [file join $new delete_log.txt]
    set log_ok [_she_append $lp "$ts MIGRATE OK from=$src to=$new items=[llength [dict get $plan all]] manifest_repointed=[dict get $res changed] manifest_kept=[dict get $res kept] audit_copy=[dict get $res audit]"]
    foreach e [dict get $plan all] {
        if {![_she_append $lp "$ts MIGRATE ITEM $e -> [file join $new $e]"]} { set log_ok 0 }
    }
    msg -NOTICE "ShotHistoryEditor: moved [join [dict get $plan all] {, }] to $new"
    return [dict merge $res [dict create ok 1 items [dict get $plan all] log_ok $log_ok]]
}

# The Move page's button: Move now... (legacy) or Finish move... (a stopped
# move), enabled only when the plan has no refusal.
proc ::plugins::ShotHistoryEditor::_refresh_migrate_now {page} {
    set plan [_she_move_plan]
    set lbl [_pick [expr {[dict get $plan state] eq "unfinished"}] [translate "Finish move..."] [translate "Move now..."]]
    catch { dui item config $page migrate_now -label $lbl }
    catch { dui item enable_or_disable [dict get $plan can] $page migrate_now* -initial 1 }
}

proc ::plugins::ShotHistoryEditor::open_migrate_confirm {} {
    if {![dict get [_she_move_plan] can]} { return }
    open_page ShotHistoryEditor_migrate_confirm
}

proc ::plugins::ShotHistoryEditor::cancel_migrate_confirm {} {
    _return_to_page ShotHistoryEditor_migrate_preview
}

# fresh 1 (the page's show): take the plan the count is typed for.
proc ::plugins::ShotHistoryEditor::refresh_migrate_confirm_page {page {fresh 0}} {
    variable migrate_snap
    variable migrate_count
    variable migrate_input
    variable migrate_error
    set plan [_she_move_plan]
    if {$fresh} {
        set migrate_snap [_she_move_snap $plan]
        set migrate_count [dict get $plan count]
        set migrate_input ""
        set migrate_error ""
    }
    if {[dict get $plan can]} {
        set from [_pick [expr {[dict get $plan src] ne {}}] [dict get $plan src] [dict get $plan staging]]
        set instr "Type $migrate_count (the number of items that end up in history_trash/), then tap Move."
        set mp [dict get $plan mplan]
        set summary [join [list \
            "From: $from" \
            "To: [dict get $plan new]" \
            "Items: [join [dict get $plan all] {, }]" \
            "The trash manifest's [llength [dict get $plan lines]] line(s) point at the new trash/ afterwards ([dict get $mp changed] re-pointed, [dict get $mp kept] already there); a copy of it is kept as trash_manifest.before_move.txt." \
            "history/ and history_v2/ are not touched. Nothing is deleted; the only copy made is that manifest copy. delete_log.txt records the move (MIGRATE lines)."] "\n"]
    } else {
        # The first reason only (the entry label sits two rows below); the
        # Move page lists them all.
        set instr "The move cannot run now: [lindex [dict get $plan refusals] 0]. Back to the Move page for the rest."
        set summary ""
    }
    catch { dui item config $page migrate_instructions -text $instr }
    catch { dui item config $page migrate_error_text -text $migrate_error }
    catch { dui item config $page migrate_summary -text $summary }
    catch { dui item enable_or_disable [dict get $plan can] $page migrate_confirm_btn* -initial 1 }
}

# The one place that calls perform_she_move.
proc ::plugins::ShotHistoryEditor::confirm_migrate_submit {} {
    variable migrate_snap
    variable migrate_count
    variable migrate_input
    variable migrate_error
    variable migrate_result_text
    set typed [string trim $migrate_input]
    if {$migrate_count eq "" || $typed ne $migrate_count} {
        set migrate_error "Type exactly \"$migrate_count\" to confirm. Nothing was moved."
        refresh_migrate_confirm_page ShotHistoryEditor_migrate_confirm
        return
    }
    set r [perform_she_move $migrate_snap]
    set lines {}
    if {[dict get $r ok]} {
        lappend lines "Moved. The plugin's trash, backups and logs are now in [dict get $r new]:"
        lappend lines "  [join [dict get $r items] {, }]"
        switch -- [dict get $r audit] {
            remade { lappend lines "The trash manifest points at the new trash/ ([dict get $r changed] line(s) re-pointed). trash_manifest.before_move.txt was missing; it was made again from the manifest as it was (already re-pointed)." }
            none   { lappend lines "There was no trash manifest to re-point." }
            default { lappend lines "The trash manifest points at the new trash/ ([dict get $r changed] line(s) re-pointed); its original is trash_manifest.before_move.txt." }
        }
        lappend lines "Nothing was deleted (the only copy made is that manifest copy); history/ and history_v2/ were not touched."
        if {![dict get $r log_ok]} { lappend lines "WARNING: a MIGRATE line could not be written to delete_log.txt; see the app log." }
        lappend lines ""
        lappend lines "Trash / Restore, Empty trash, Tidy, Reconcile and every save use the new folder from now on."
    } else {
        lappend lines [dict get $r message]
    }
    set migrate_result_text [join $lines "\n"]
    set migrate_snap ""
    open_page ShotHistoryEditor_migrate_result
}

# Appends one line (creating SHE's folder first if needed); 1 when it is on
# disk, 0 (logged -ERROR) when not. Every trash-record append uses it, so a
# failed one is never silent.
proc ::plugins::ShotHistoryEditor::_she_append {path line} {
    if {[catch {
        set dir [file dirname $path]
        if {![file isdirectory $dir]} { file mkdir $dir }
        set fh [open $path a]
        fconfigure $fh -encoding utf-8
        puts $fh $line
        close $fh
    } err]} {
        if {[info exists fh]} { catch { close $fh } }
        msg -ERROR "ShotHistoryEditor: could not append to $path: $err"
        return 0
    }
    return 1
}

# ---------------------------------------------------------------------------
# Pass 4.0 -- soft delete: trash folder, manifest, and audit log.
#
# Step 1 finding (see README/CHANGELOG for the full writeup): nothing in this
# workspace indexes, watches, or rebuilds from history_v2/*.json filenames --
# grepping plugins/SDB/SDB.tcl, plugins/GrindAdvisor/GrindAdvisor.tcl, and
# plugins/visualizer_upload/plugin.tcl for "history_v2" or ".json" returns no
# matches at all, and history_v2/ itself contains no index/manifest file, only
# loose per-shot json files. SDB's own resync/rebuild path
# (::plugins::SDB::populate/::plugins::SDB::create) is driven entirely from
# history/*.shot. Given that, and per this plugin's own docs ("history_v2 is
# secondary; verify safety before touching it"), this pass moves BOTH the
# .shot and its matching .json (when present) together into the same trash
# batch -- there is no functional reason to leave an orphaned json behind
# with no consumer, and leaving one on disk would only be clutter.
# ---------------------------------------------------------------------------

proc ::plugins::ShotHistoryEditor::trash_dir {} {
    return [_she_entry_path trash]
}

proc ::plugins::ShotHistoryEditor::trash_manifest_path {} {
    return [_she_entry_path trash_manifest.txt]
}

proc ::plugins::ShotHistoryEditor::delete_log_path {} {
    return [_she_entry_path delete_log.txt]
}

# Filenames here always originate from SDB's own `filename` column (never
# free-typed by a user), but this plugin never trusts that fully: reject
# anything that looks like a path or a traversal attempt before it is ever
# used to build a move destination.
proc ::plugins::ShotHistoryEditor::_safe_filename {fn} {
    if {$fn eq ""} { return 0 }
    if {[string match {*[/\\]*} $fn]} { return 0 }
    if {[string first ".." $fn] >= 0} { return 0 }
    return 1
}

proc ::plugins::ShotHistoryEditor::_new_batch_id {} {
    return [format "%04x" [expr {int(rand()*65536)}]]
}

# ---------------------------------------------------------------------------
# Pass 5.0 -- real metadata save: backups, edit manifest, audit log.
#
# Step 1 findings (see README/CHANGELOG for the full writeup):
#
# a) .shot format: a flat "key value" line per top-level entry, plus one
#    `settings {` ... `}` block containing the user-facing metadata as
#    tab-indented "key value" lines in the SAME flat style. Inspecting the
#    3 sample files in history/*.shot shows the settings{} block itself
#    contains a NESTED sub-value (`read_only_backup {...}`, a backup copy of
#    prior settings) that spans many lines and is NOT balanced within a
#    single line -- a naive scan for the first bare closing-brace line (which is
#    exactly what this plugin's own read_legacy_settings/_parse_settings_file
#    already does, and is harmless for reading only because every editable
#    field's key happens to sort alphabetically before "read_only_backup")
#    would stop partway through the real settings{} block. That is fine for
#    read-only display, but WRITING against a truncated boundary risks
#    corrupting/truncating the file, so the write path below tracks brace
#    depth properly (_settings_block_bounds/_find_settings_key_line) to find
#    the block's true end and the exact target key's line, instead of
#    reusing the existing (unmodified, still fine for reading) parser.
# b) plugins/SDB/SDB.tcl:2948 calls `modify_shot_file $path new_settings`
#    (via `get_shot_file_path`) to edit categories in a .shot file --
#    proving targeted .shot-file edits are a normal, supported operation.
#    (v0.20.0 correction: both are SDB's own procs, ::plugins::SDB::
#    modify_shot_file at SDB.tcl:1248 and get_shot_file_path at :1024, not
#    core procs.) SDB's call site follows it with `db eval "UPDATE ..."`
#    against SDB in the same breath (SDB.tcl:2954-2973), which this plugin
#    must never do -- so this pass does not call modify_shot_file and
#    instead implements its own self-contained, verified read-modify-
#    temp-write-rename cycle below, touching only the one targeted
#    settings{} line and nothing else in the file.
# c) history_v2/<filename>.json is NOT written in this pass. Per the same
#    evidence as the delete pass (no plugin or manifest in this workspace
#    reads/depends on it), and because its meta.bean/meta.grinder structure
#    uses different key names than the .shot settings block (so keeping it
#    in sync would require a second, separate write path with no proven
#    need), this pass leaves it untouched. This means history_v2 can show a
#    stale value for an edited field until/unless a future pass addresses
#    it -- documented in README/Help, same as the existing SDB-staleness
#    note.
# d) SDB is never written to, so the card list and Detail page's SDB column
#    would otherwise keep showing the pre-edit value. Reusing the delete
#    pass's manifest-overlay pattern: an edit_manifest.txt entry per saved
#    field is read back and overlaid onto SDB-sourced values before display
#    (_all_edit_overlays/_apply_edit_overlay), so the user sees their
#    correction immediately even though SDB itself is untouched and may
#    resync on its own.
# ---------------------------------------------------------------------------

proc ::plugins::ShotHistoryEditor::backups_dir {} {
    return [_she_entry_path backups]
}

proc ::plugins::ShotHistoryEditor::edit_manifest_path {} {
    return [_she_entry_path edit_manifest.txt]
}

proc ::plugins::ShotHistoryEditor::edit_log_path {} {
    return [_she_entry_path edit_log.txt]
}

# Tcl-list-safe quoting for a single value being written back into a
# "key value" settings line (mirrors how this file format already quotes
# multi-word/list values, e.g. "chart_dashes_espresso_weight {2 1}").
proc ::plugins::ShotHistoryEditor::_tcl_quote_value {v} {
    return [list $v]
}

# Finds the [start end] line indices (0-based, inclusive) of the outermost
# `settings { ... }` block by tracking brace depth across the whole file,
# rather than stopping at the first bare closing-brace line -- see finding (a) above.
# Returns {-1 -1} if no settings{} block is found.
proc ::plugins::ShotHistoryEditor::_settings_block_bounds {lines} {
    set n [llength $lines]
    set start -1
    set depth 0
    for {set i 0} {$i < $n} {incr i} {
        set line [lindex $lines $i]
        if {$start < 0} {
            if {[string trim $line] eq "settings \{"} {
                set start $i
                set o [regexp -all -- {\{} $line]
                set c [regexp -all -- {\}} $line]
                set depth [expr {$o - $c}]
                if {$depth <= 0} { return [list $start $i] }
            }
            continue
        }
        set o [regexp -all -- {\{} $line]
        set c [regexp -all -- {\}} $line]
        incr depth [expr {$o - $c}]
        if {$depth <= 0} { return [list $start $i] }
    }
    return [list -1 -1]
}

# Finds the line index of $key's entry directly inside the settings{} block
# (depth exactly 1, i.e. not nested inside a sub-value like
# read_only_backup), scanning the WHOLE block and keeping the LAST match --
# matching how _parse_settings_file's `dict set values $key $val` naturally
# lets a later occurrence win. Returns -1 if not found at depth 1.
proc ::plugins::ShotHistoryEditor::_find_settings_key_line {lines start end key} {
    set found -1
    set depth 1
    for {set i [expr {$start + 1}]} {$i < $end} {incr i} {
        set line [lindex $lines $i]
        set trimmed [string trim $line]
        if {$depth == 1 && $trimmed ne ""} {
            if {![catch { lindex $trimmed 0 } k] && $k eq $key} {
                set found $i
            }
        }
        set o [regexp -all -- {\{} $line]
        set c [regexp -all -- {\}} $line]
        incr depth [expr {$o - $c}]
    }
    return $found
}

# v0.23.1: through _she_append (a failed line is logged -ERROR, never
# swallowed); 1 when the line is on disk.
proc ::plugins::ShotHistoryEditor::_append_edit_manifest {ts filename field old_value new_value backup_path} {
    return [_she_append [edit_manifest_path] "$ts|$filename|$field|$old_value|$new_value|$backup_path"]
}

proc ::plugins::ShotHistoryEditor::_append_edit_log {ts filename field old_value new_value backup_path status} {
    return [_she_append [edit_log_path] \
        "$ts EDIT $status filename=$filename field=$field old=[_display $old_value] new=[_display $new_value] backup=$backup_path"]
}

proc ::plugins::ShotHistoryEditor::_edit_manifest_lines {} {
    set path [edit_manifest_path]
    if {![file isfile $path]} { return {} }
    set lines {}
    if {[catch {
        set fh [open $path r]
        fconfigure $fh -encoding utf-8
        while {[gets $fh line] >= 0} {
            set line [string trim $line]
            if {$line ne ""} { lappend lines $line }
        }
        close $fh
    }]} {
        catch { close $fh }
    }
    return $lines
}

# Manifest line format: timestamp|filename|field|old|new|backup_path (v0.5.0,
# values raw), or the same plus |e1|epoch with old/new escaped (v0.17.0 bag
# Save; epoch = the save's clock seconds).
proc ::plugins::ShotHistoryEditor::_edit_manifest_records {} {
    set records {}
    foreach line [_edit_manifest_lines] {
        set parts [split $line "|"]
        if {[llength $parts] == 8 && [lindex $parts 6] eq "e1" && [string is wideinteger -strict [lindex $parts 7]]} {
            lassign $parts ts filename field old_value new_value backup_path - epoch
            set old_value [_unesc $old_value]
            set new_value [_unesc $new_value]
            set e1 1
        } elseif {[llength $parts] == 6} {
            lassign $parts ts filename field old_value new_value backup_path
            set e1 0
            set epoch ""
        } else {
            continue
        }
        lappend records [dict create ts $ts filename $filename field $field \
            old_value $old_value new_value $new_value backup_path $backup_path e1 $e1 epoch $epoch]
    }
    return $records
}

# filename -> field -> every record {new old e1 epoch}, in manifest order, built
# once per list refresh.
proc ::plugins::ShotHistoryEditor::_all_edit_overlays {} {
    set overlays [dict create]
    foreach rec [_edit_manifest_records] {
        set fn [dict get $rec filename]
        set field [dict get $rec field]
        set l {}
        if {[dict exists $overlays $fn $field]} { set l [dict get $overlays $fn $field] }
        lappend l [list [dict get $rec new_value] [dict get $rec old_value] [dict get $rec e1] [dict get $rec epoch]]
        dict set overlays $fn $field $l
    }
    return $overlays
}

# Overlays edited values onto an SDB row so the change shows at once, before
# SDB resyncs. A v0.5.0 record applies as before (always). A v0.17.0 bag-save
# record (e1) is for the time until SDB re-reads the file: SDB's
# file_modification_date at or past the save's epoch means the row already
# holds that save, and everything before it, so the fold starts after the
# last such save from the row's own value (a later revert in DYE shows as
# it is). The e1 records SDB has not caught up with apply in order, each
# only when the value so far is the one it replaced: a chain A to B to C
# shows C. With no file_modification_date column, the value test alone.
proc ::plugins::ShotHistoryEditor::_apply_edit_overlay {row overlays} {
    set filename [_dget $row filename]
    if {$filename eq "" || ![dict exists $overlays $filename]} { return $row }
    set fmd [_dget $row file_modification_date]
    set known [string is double -strict $fmd]
    dict for {field recs} [dict get $overlays $filename] {
        if {![dict exists $row $field]} { continue }
        set from 0
        if {$known} {
            set i 0
            foreach rec $recs {
                lassign $rec new old e1 epoch
                incr i
                if {$e1 && $fmd >= $epoch} { set from $i }
            }
        }
        set v [dict get $row $field]
        foreach rec [lrange $recs $from end] {
            lassign $rec new old e1 epoch
            if {!$e1 || [string trim $v] eq [string trim $old]} { set v $new }
        }
        dict set row $field $v
    }
    return $row
}

# Real write path: modifies ONLY the one targeted settings{} key line of
# history/<filename>.shot, preserving every other byte (including the raw
# data arrays, which live entirely outside the settings{} block and are
# never touched). Backs up before writing, verifies the temp file with the
# proven _parse_settings_file reader before ever touching the original, and
# additionally re-verifies after the rename with an automatic restore-from-
# backup as a second safety net (per the requested design). Never calls
# `file delete`: a failed pre-rename verification simply leaves the temp
# file behind (harmless, and the original was never touched); a failed
# post-rename verification restores via `file rename` from the backup.
# Tell Grind Advisor that this plugin changed what is on disk, so its
# recommendation follows without anyone having to know that it should. Its
# refresh_from_history asks SDB to resync, drops its per-bag cache, recomputes
# for the loaded bag and re-saves. Returns its human-readable summary, or ""
# when it is not installed or the call failed.
#
# Guarded on both existence and errors: by the time this is called THIS
# plugin's own work has already succeeded, and it must report success whatever
# another plugin does.
#
# Answering the obvious question -- why not refresh on every recommendation
# lookup instead? Because the resync rescans the whole history folder. Once
# per edit or per delete batch is the right moment to spend that; a display
# tick is not.
#
# v0.6.3: this was inline in perform_metadata_edit and nowhere else, so an
# edit updated the recommendation and a DELETE did not -- owner-reported from
# the tablet, the same symptom as the v0.6.0 edit bug and the same cause one
# path over. Deleting needs no mtime trick, unlike editing: SDB's populate
# flags a vanished file `removed=1` by absence alone, and Grind Advisor
# already filters that column in its SQL. The notification was the only
# missing link. Kept as ONE proc so the three paths cannot drift apart.
#
# `what` is a short phrase for the log line, e.g. "the edit", "the delete".
proc ::plugins::ShotHistoryEditor::_refresh_grind_advisor {what} {
    if {[info procs ::plugins::GrindAdvisor::refresh_from_history] eq ""} { return "" }
    set note ""
    if {[catch { set note [::plugins::GrindAdvisor::refresh_from_history] } err]} {
        catch { msg -NOTICE "ShotHistoryEditor: Grind Advisor refresh failed after $what: $err" }
        return ""
    }
    catch { msg -INFO "ShotHistoryEditor: Grind Advisor refreshed after $what: $note" }
    return $note
}

# Everything downstream that should follow a change to history/, in order
# (v0.7.0). Called wherever _refresh_grind_advisor used to be called alone.
#
#   1. Grind Advisor first: its refresh_from_history resyncs SDB, which the
#      next step reads.
#   2. The Lumen skin second: refresh_after_history_change reloads the home
#      page's last-shot chart and card from the (possibly new) newest shot
#      file, and rebuilds the bag cycler from the freshly-resynced SDB.
#
# Each is guarded on existence -- a different skin, or no Grind Advisor,
# simply skips its step -- and on errors, because this plugin's own work has
# already succeeded by the time this runs. Returns Grind Advisor's summary
# for the result pages, same contract as _refresh_grind_advisor.
proc ::plugins::ShotHistoryEditor::_notify_downstream {what} {
    set note [_refresh_grind_advisor $what]
    if {[info procs ::lumen::refresh_after_history_change] ne ""} {
        if {[catch { ::lumen::refresh_after_history_change } err]} {
            catch { msg -NOTICE "ShotHistoryEditor: Lumen refresh failed after $what: $err" }
        } else {
            catch { msg -INFO "ShotHistoryEditor: Lumen home refreshed after $what" }
        }
    }
    return $note
}

proc ::plugins::ShotHistoryEditor::perform_metadata_edit {filename field new_value} {
    variable editable_fields

    set new_value [string trim $new_value]
    # v0.22.0: its backup and logs go to SHE's folder, so not while that
    # folder is being moved or is in two places.
    set why [_she_write_blocker]
    if {$why ne ""} {
        return [dict create ok 0 message "Not saved: $why." old_value "" new_value $new_value backup_path ""]
    }
    if {$new_value eq ""} {
        return [dict create ok 0 message "New value is empty; nothing was written." \
            old_value "" new_value "" backup_path ""]
    }
    # v0.23.0: the bag Save's own rules (final-check review). A brace or a
    # backslash breaks the plugin's line readers for that file; a save while
    # the DE1 runs or SDB syncs races the app's own writers.
    set vp [_bag_value_problem $field $new_value]
    if {$vp ne ""} {
        return [dict create ok 0 message "Not saved: $field $vp." old_value "" new_value $new_value backup_path ""]
    }
    set busy [_machine_busy]
    if {$busy ne ""} {
        return [dict create ok 0 message "Not saved: the machine is busy ($busy); save when it is idle." \
            old_value "" new_value $new_value backup_path ""]
    }
    if {[_sdb_busy]} {
        return [dict create ok 0 message "Not saved: SDB is syncing; try again in a moment." \
            old_value "" new_value $new_value backup_path ""]
    }
    if {[lsearch -exact $editable_fields $field] < 0} {
        return [dict create ok 0 message "'$field' is not in the safe editable field list." \
            old_value "" new_value $new_value backup_path ""]
    }
    if {![_safe_filename $filename]} {
        return [dict create ok 0 message "Unsafe filename." old_value "" new_value $new_value backup_path ""]
    }
    set path [_legacy_file $filename]
    if {![file isfile $path]} {
        return [dict create ok 0 message "history/$filename.shot not found." \
            old_value "" new_value $new_value backup_path ""]
    }

    if {[catch {
        set fh [open $path r]
        fconfigure $fh -encoding utf-8 -translation lf
        set raw [read $fh]
        close $fh
    } err]} {
        if {[info exists fh]} { catch { close $fh } }
        return [dict create ok 0 message "Could not read $path: $err" \
            old_value "" new_value $new_value backup_path ""]
    }
    set had_trailing_nl [string match "*\n" $raw]
    set lines [split $raw "\n"]
    if {$had_trailing_nl} { set lines [lrange $lines 0 end-1] }

    lassign [_settings_block_bounds $lines] sstart send
    if {$sstart < 0} {
        return [dict create ok 0 message "No settings {} block found in $path." \
            old_value "" new_value $new_value backup_path ""]
    }
    set key_idx [_find_settings_key_line $lines $sstart $send $field]
    if {$key_idx < 0} {
        return [dict create ok 0 message "Field '$field' not found in the settings block of $path." \
            old_value "" new_value $new_value backup_path ""]
    }

    set orig_line [lindex $lines $key_idx]
    set trimmed [string trim $orig_line]
    set old_value [_clean_value [join [lrange $trimmed 1 end] " "]]
    if {![regexp -- {^(\s*)(\S+)} $orig_line -> ws k]} {
        return [dict create ok 0 message "Could not parse the existing '$field' line." \
            old_value $old_value new_value $new_value backup_path ""]
    }

    set new_line "$ws$field [_tcl_quote_value $new_value]"
    set new_lines [lreplace $lines $key_idx $key_idx $new_line]
    set new_content [join $new_lines "\n"]
    if {$had_trailing_nl} { append new_content "\n" }

    set ts [clock format [clock seconds] -format {%Y%m%dT%H%M%S}]
    set batch_id [_new_batch_id]
    set backup_dir [file join [backups_dir] "${ts}_${batch_id}"]
    set backup_path [file join $backup_dir "$filename.shot"]
    if {[catch { file mkdir $backup_dir } err]} {
        return [dict create ok 0 message "Could not create backup folder: $err" \
            old_value $old_value new_value $new_value backup_path ""]
    }
    if {[catch { file copy -- $path $backup_path } err]} {
        return [dict create ok 0 message "Could not create backup: $err" \
            old_value $old_value new_value $new_value backup_path ""]
    }
    # v0.23.2: the backup is checked byte for byte first, as the bag Save's
    # are; a failed save below is put back from it and checked again.
    set orig_bytes [_read_bytes_or_empty $path]
    if {$orig_bytes eq "" || [_read_bytes_or_empty $backup_path] ne $orig_bytes} {
        return [dict create ok 0 message "Could not create backup: the copy at $backup_path does not match the original; nothing was written." \
            old_value $old_value new_value $new_value backup_path ""]
    }

    set tmp_path "${path}.tmp${batch_id}"
    if {[catch {
        set th [open $tmp_path w]
        fconfigure $th -encoding utf-8 -translation lf
        puts -nonewline $th $new_content
        close $th
    } err]} {
        if {[info exists th]} { catch { close $th } }
        return [dict create ok 0 message "Could not write temp file: $err" \
            old_value $old_value new_value $new_value backup_path $backup_path]
    }

    set verify1 [_parse_settings_file $tmp_path]
    set verify1_val [_dget [_dget $verify1 values] $field]
    if {[dict get $verify1 status] ne "found" || $verify1_val ne $new_value} {
        return [dict create ok 0 \
            message "Verification failed before saving; the original file was not touched. Temp file left at $tmp_path for inspection." \
            old_value $old_value new_value $new_value backup_path $backup_path]
    }

    if {[catch { file rename -force -- $tmp_path $path } err]} {
        return [dict create ok 0 message "Could not replace the original file: $err" \
            old_value $old_value new_value $new_value backup_path $backup_path]
    }

    set verify2 [_parse_settings_file $path]
    set verify2_val [_dget [_dget $verify2 values] $field]
    if {[dict get $verify2 status] ne "found" || $verify2_val ne $new_value} {
        # v0.23.2: copied back (the backup stays) and checked, never
        # reported as restored when it was not.
        set rs [_bag_restore $path $backup_path $orig_bytes "FAILED post-rename verification"]
        if {[dict get $rs status] eq "restore_failed"} {
            msg -ERROR "ShotHistoryEditor: $path did not verify after the save and could not be put back; the intact copy is $backup_path"
            _append_edit_log $ts $filename $field $old_value $new_value $backup_path [dict get $rs reason]
            return [dict create ok 0 \
                message "Save did not verify after writing, and the original could NOT be put back. The intact copy is $backup_path: copy it over history/$filename.shot by hand." \
                old_value $old_value new_value $new_value backup_path $backup_path]
        }
        _append_edit_log $ts $filename $field $old_value $new_value $backup_path "[dict get $rs reason] (checked)"
        return [dict create ok 0 \
            message "Save did not verify after writing; the original was restored from its backup (checked byte for byte)." \
            old_value $old_value new_value $new_value backup_path $backup_path]
    }

    # v0.6.0: make the file LOOK modified, because it is.
    #
    # MEASURED ON THE TABLET, 2026-08-19. The 16:44:30 shot was edited at
    # 16:45:30 (grinder_setting 7.5 -> 8; the edit_log records it and the file
    # does contain 8). Its modification time was still 1787057093 = 16:44:53 --
    # the moment the app first WROTE the shot. `file rename` landed the
    # replacement carrying the original's timestamp. (v0.21.0: why is not
    # known. It was not a copy fallback, as this note used to say: a
    # 2026-10-21 probe showed renames on this storage keep the inode. The
    # explicit stamp below is what fixed it.)
    #
    # That silently defeats every consumer that detects edits by mtime.
    # SDB re-reads a .shot only when `file mtime > file_modification_date`
    # (SDB.tcl:2060), and SDB's stored value for that shot was 1787057093 --
    # byte-identical to the file's. Not greater, so it was skipped, and would
    # have been skipped forever. Confirmed by reading SDB read-only: the row
    # still said grinder_setting '7.5' while the file said 8.
    #
    # So SDB's OWN "Resync database to history" button could never pick up an
    # edit made by this plugin, and neither could anything downstream of it --
    # which is exactly what the owner reported about Grind Advisor.
    #
    # One `file mtime` stamp on the file this proc has just legitimately
    # rewritten. No content is touched. It is deliberately AFTER the
    # post-rename verification, so a save that failed verification and was
    # rolled back never stamps anything.
    if {[catch { file mtime $path [clock seconds] } err]} {
        catch { msg -NOTICE "ShotHistoryEditor: could not stamp the modification time of $path: $err (SDB will not see this edit until it is resynced another way)" }
    }

    set log_ok [_append_edit_manifest $ts $filename $field $old_value $new_value $backup_path]
    if {![_append_edit_log $ts $filename $field $old_value $new_value $backup_path "OK"]} { set log_ok 0 }

    # v0.24.0: the same field in history_v2/<f>.json (capability 10). Its
    # result never undoes the .shot write above.
    set v2 [_v2_save $ts $filename [list $field $new_value] $backup_dir]

    # v0.6.0: tell Grind Advisor, so the recommendation follows the correction
    # without anyone having to know that it should. v0.6.3 shared that with
    # the delete and restore paths; v0.7.0 widened it to the Lumen home page.
    set note [_notify_downstream "the edit"]

    return [dict create ok 1 message "" old_value $old_value new_value $new_value \
        backup_path $backup_path refresh_note $note log_ok $log_ok v2 $v2]
}

# SQL string-literal quoting (distinct from _q, which quotes identifiers).
# Used only to look up metadata for an already-known, internally-sourced
# list of filenames -- never for free-form user input.
proc ::plugins::ShotHistoryEditor::_qval {s} {
    return "'[string map {' ''} $s]'"
}

# v0.23.1: the manifest's non-empty lines, or why it could not be read --
# all of it or nothing, never a partial list (the move rewrites from it).
# A missing file is an empty manifest -- except with must_exist 1
# (v0.23.3: Restore, Empty trash and the move, which rewrite from what they
# read): then a file that is not there, or a stat that says so, is ok 0, so
# a passing glitch can never make them write an empty manifest. Only the
# delete path reads leniently (its own append-open has just created it).
proc ::plugins::ShotHistoryEditor::_manifest_read {path {must_exist 0}} {
    if {![file isfile $path]} {
        if {$must_exist} {
            msg -ERROR "ShotHistoryEditor: the trash manifest $path is not there (or cannot be seen)"
            return [dict create ok 0 lines {} err "it is not there"]
        }
        return [dict create ok 1 lines {} err ""]
    }
    if {[catch {
        set fh [open $path r]
        fconfigure $fh -encoding utf-8
        set raw [read $fh]
        close $fh
    } err]} {
        if {[info exists fh]} { catch { close $fh } }
        msg -ERROR "ShotHistoryEditor: could not read $path: $err"
        return [dict create ok 0 lines {} err $err]
    }
    set lines {}
    foreach line [split $raw "\n"] {
        set line [string trim $line]
        if {$line ne ""} { lappend lines $line }
    }
    return [dict create ok 1 lines $lines err ""]
}

# v0.21.0: path defaults to the live manifest; the move preview reads the
# one in the folder it found. v0.23.1: a failed read is logged (-ERROR).
proc ::plugins::ShotHistoryEditor::_manifest_lines {{path ""}} {
    if {$path eq ""} { set path [trash_manifest_path] }
    return [dict get [_manifest_read $path] lines]
}

# Manifest line format (one per moved FILE, not per shot):
#   timestamp|original_path|trash_path|batch_id
proc ::plugins::ShotHistoryEditor::_manifest_records {{path ""}} {
    set records {}
    foreach line [_manifest_lines $path] {
        set parts [split $line "|"]
        if {[llength $parts] != 4} { continue }
        lassign $parts ts orig trash batch
        lappend records [dict create ts $ts orig $orig trash $trash batch $batch]
    }
    return $records
}

# v0.20.0: where a manifest record's file belongs on disk NOW. The manifest
# keeps the absolute `orig` path written at delete time, so a batch trashed
# under an older data root must come back under the current one: every disk
# use of `orig` (restore_batch, _reconcile_records, perform_unhide) maps it by
# name -- <name>.shot into [history_path], <name>.json into [history_v2_path].
# Returns "" (the caller refuses the record) for any other extension, a name
# that is not a plain file name, a trash copy of another name, or a result
# that is not directly inside one of those two folders. The manifest and
# reconcile key strings are never rewritten.
proc ::plugins::ShotHistoryEditor::_rebased_orig {orig {trash ""}} {
    set name [file tail $orig]
    if {![_safe_filename $name] || [file rootname $name] eq ""} { return "" }
    if {$trash ne "" && [file tail $trash] ne $name} { return "" }
    switch -exact -- [file extension $name] {
        .shot   { set folder [history_path] }
        .json   { set folder [history_v2_path] }
        default { return "" }
    }
    set target [file join $folder $name]
    if {[file dirname [file normalize $target]] ne [file normalize $folder]} { return "" }
    return $target
}

# v0.23.2: the one way the trash manifest is replaced (Restore, Empty trash,
# and each delete's new lines): the whole new text to trash_manifest.txt.new,
# read back byte for byte, then one rename over trash_manifest.txt. A
# failure at any step leaves the manifest as it was (no truncated or
# half-written manifest) and is logged -ERROR. Returns 1 or 0.
proc ::plugins::ShotHistoryEditor::_manifest_write {lines} {
    set mf [trash_manifest_path]
    set tmp "$mf.new"
    set want ""
    if {[llength $lines]} { set want "[join $lines \n]\n" }
    if {[catch {
        set fh [open $tmp w]
        fconfigure $fh -encoding utf-8 -translation lf
        puts -nonewline $fh $want
        close $fh
    } err]} {
        if {[info exists fh]} { catch { close $fh } }
        msg -ERROR "ShotHistoryEditor: could not write $tmp: $err"
        return 0
    }
    if {[catch { _read_bytes $tmp } got] || $got ne [encoding convertto utf-8 $want]} {
        msg -ERROR "ShotHistoryEditor: $tmp did not read back as written; $mf is unchanged"
        return 0
    }
    if {[catch { file rename -force -- $tmp $mf } err]} {
        msg -ERROR "ShotHistoryEditor: could not replace $mf: $err"
        return 0
    }
    return 1
}

# v0.22.0: no longer swallowed (final-check refuter: a lost manifest line
# after the files moved loses the record of where they went). Returns
# manifest_ok and log_ok; perform_delete_batch puts the files back when the
# manifest line could not be written. v0.23.2: the lines go in through
# _manifest_write (all of the batch or none: a partial append on a full
# disk used to leave lines naming files that were then put back).
proc ::plugins::ShotHistoryEditor::_append_manifest_and_log {moved batch_id ts shot_count} {
    if {[llength $moved] == 0} { return [dict create manifest_ok 1 log_ok 1] }
    set lines {}
    foreach m $moved {
        lassign $m fn src dst
        lappend lines "$ts|$src|$dst|$batch_id"
    }
    set rd [_manifest_read [trash_manifest_path]]
    set manifest_ok 0
    if {[dict get $rd ok]} { set manifest_ok [_manifest_write [concat [dict get $rd lines] $lines]] }
    set log_ok 0
    if {$manifest_ok} {
        set log_ok [_she_append [delete_log_path] \
            "$ts DELETE batch=$batch_id shots=$shot_count files=[llength $moved] -> [trash_dir]/${ts}_${batch_id}"]
    }
    return [dict create manifest_ok $manifest_ok log_ok $log_ok]
}

# v0.22.0: the files of a batch whose manifest lines could not be written go
# back where they came from (newest first, never over an existing file).
# Returns the trash paths that could not be put back (reported, never lost).
proc ::plugins::ShotHistoryEditor::_delete_put_back {moved} {
    set stuck {}
    foreach m [lreverse $moved] {
        lassign $m fn src dst
        if {[file exists $src]} {
            msg -ERROR "ShotHistoryEditor: $dst not put back: $src exists"
            lappend stuck $dst
        } elseif {[catch { file rename -- $dst $src } err]} {
            msg -ERROR "ShotHistoryEditor: $dst not put back to $src: $err"
            lappend stuck $dst
        }
    }
    return $stuck
}

proc ::plugins::ShotHistoryEditor::_append_restore_log {batch_id restored collisions {refused 0} {manifest_ok 1} {failed 0}} {
    set ts [clock format [clock seconds] -format {%Y%m%dT%H%M%S}]
    return [_she_append [delete_log_path] \
        "$ts RESTORE batch=$batch_id restored_files=$restored collisions=$collisions refused=$refused manifest_rewritten=$manifest_ok failed=$failed"]
}

# Base shot filenames (no extension) currently hidden because their .shot
# was moved to trash. Rebuilt from the manifest on demand; this is what
# every shot list filters against so deleted shots disappear immediately
# even though SDB still has their rows untouched.
proc ::plugins::ShotHistoryEditor::_deleted_filenames_dict {} {
    set d [dict create]
    # v0.10.0: a manifest line that has been unhidden (reconcile manifest,
    # keyed to that exact line) hides nothing any more.
    set reconciled [_reconciled_keys_dict]
    foreach rec [_manifest_records] {
        set orig [dict get $rec orig]
        if {[string match "*.shot" $orig]} {
            if {[dict exists $reconciled [_manifest_key $rec]]} { continue }
            dict set d [file rootname [file tail $orig]] 1
        }
    }
    return $d
}

proc ::plugins::ShotHistoryEditor::deleted_shot_count {} {
    return [dict size [_deleted_filenames_dict]]
}

# ---------------------------------------------------------------------------
# v0.9.0 -- reconciliation view (READ-ONLY). A trash-manifest line hides its
# shot from every list here for as long as the line stands. If the original
# path is populated again meanwhile -- seen for real on 2026-08-24, when the
# core's flush-save bug parked a corpse under a restored shot's name; also a
# hand copy, or a restore whose manifest rewrite failed -- the shot is on
# disk and SDB re-lists it on its next resync, yet this plugin neither shows
# it nor lets you delete it, and Restore reports a collision for it. This
# pass only SURFACES that state (Advanced > Reconcile hidden shots). The
# action (un-hide, or forget the stale line) is a later, separately
# authorized pass. Nothing below writes anything.
# ---------------------------------------------------------------------------

proc ::plugins::ShotHistoryEditor::_reconcile_records {} {
    set out {}
    set reconciled [_reconciled_keys_dict]
    foreach rec [_manifest_records] {
        set orig [dict get $rec orig]
        if {![string match "*.shot" $orig]} { continue }
        # v0.20.0: "on disk again" means in the CURRENT history folder; `orig`
        # stays the manifest's own string (Unhide's key is built from it).
        set disk [_rebased_orig $orig]
        if {$disk eq "" || ![file exists $disk]} { continue }
        if {[dict exists $reconciled [_manifest_key $rec]]} { continue }
        set trash [dict get $rec trash]
        set trash_exists [file exists $trash]
        set disk_mtime ""
        set trash_mtime ""
        catch { set disk_mtime [file mtime $disk] }
        if {$trash_exists} { catch { set trash_mtime [file mtime $trash] } }
        lappend out [dict create filename [file rootname [file tail $orig]] orig $orig disk $disk \
            trash $trash trash_exists $trash_exists ts [dict get $rec ts] \
            batch [dict get $rec batch] disk_mtime $disk_mtime trash_mtime $trash_mtime]
    }
    return [lsort -command ::plugins::ShotHistoryEditor::_batch_ts_cmp -decreasing $out]
}

proc ::plugins::ShotHistoryEditor::reconcile_count {} {
    return [llength [_reconcile_records]]
}

# SDB's view of a known list of filenames: "listed", "flagged removed", or
# absent from the dict. One read-only SELECT on the same handle path every
# other reader uses; filenames come from the manifest, never typed.
proc ::plugins::ShotHistoryEditor::_sdb_presence {filenames} {
    set presence [dict create]
    if {[llength $filenames] == 0} { return $presence }
    set db [_open_ro_db]
    if {$db eq ""} { return $presence }
    set table [_choose_source $db]
    if {$table ne ""} {
        set cols [_columns $db $table]
        if {[_has_col $cols filename]} {
            set removed_expr [expr {[_has_col $cols removed] ? [_q removed] : "NULL"}]
            set in_list [join [lmap fn $filenames { _qval $fn }] ", "]
            if {[catch {
                $db eval "SELECT [_q filename] AS fn, $removed_expr AS rm FROM [_q $table] WHERE [_q filename] IN ($in_list)" row {
                    set flagged [expr {[string is integer -strict $row(rm)] && $row(rm) != 0}]
                    dict set presence $row(fn) [expr {$flagged ? "flagged removed" : "listed"}]
                }
            } err]} {
                msg -NOTICE "ShotHistoryEditor: reconcile SDB lookup failed: $err"
            }
        }
    }
    _close_db
    return $presence
}

proc ::plugins::ShotHistoryEditor::_fmt_mtime {t} {
    if {$t eq ""} { return "unknown" }
    return [_fmt_time $t]
}

# ---------------------------------------------------------------------------
# v0.10.0 -- reconcile ACTION "Unhide" (the fifth authorized write
# capability). Writes exactly two plugin-owned files and nothing else:
#   - reconcile_manifest.txt: one appended line per unhide,
#       unhidden_at|ts|orig|batch   (ts|orig|batch = the trash-manifest line)
#   - delete_log.txt: one appended RECONCILE UNHIDE audit line.
# The trash manifest is NEVER edited by this path (so a still-present trash
# copy stays tracked and Restore keeps reporting its collision), no file is
# moved, and history/ is not touched. The marker is keyed to the exact
# manifest line, so deleting the same shot again later creates a new line
# that hides it again; that re-delete is also the in-app undo.
# ---------------------------------------------------------------------------

proc ::plugins::ShotHistoryEditor::reconcile_manifest_path {} {
    return [_she_entry_path reconcile_manifest.txt]
}

proc ::plugins::ShotHistoryEditor::_manifest_key {rec} {
    return "[dict get $rec ts]|[dict get $rec orig]|[dict get $rec batch]"
}

# Keys (ts|orig|batch) of every trash-manifest line that has been unhidden.
proc ::plugins::ShotHistoryEditor::_reconciled_keys_dict {} {
    set d [dict create]
    set path [reconcile_manifest_path]
    if {![file isfile $path]} { return $d }
    if {[catch {
        set fh [open $path r]
        fconfigure $fh -encoding utf-8
        while {[gets $fh line] >= 0} {
            set parts [split [string trim $line] "|"]
            if {[llength $parts] != 4} { continue }
            dict set d "[lindex $parts 1]|[lindex $parts 2]|[lindex $parts 3]" 1
        }
        close $fh
    }]} {
        catch { close $fh }
    }
    return $d
}

proc ::plugins::ShotHistoryEditor::_append_reconcile_log {now orig batch} {
    return [_she_append [delete_log_path] \
        "$now RECONCILE UNHIDE orig=$orig batch=$batch (trash entry kept, shot visible again)"]
}

# The one write of this capability. Refuses unless the manifest line still
# exists, the file is really on disk, and it was not unhidden already.
proc ::plugins::ShotHistoryEditor::perform_unhide {ts orig batch} {
    set why [_she_write_blocker]
    if {$why ne ""} { return [dict create ok 0 message "$why; nothing written."] }
    set key "$ts|$orig|$batch"
    set found 0
    foreach rec [_manifest_records] {
        if {[_manifest_key $rec] eq $key} { set found 1; break }
    }
    if {!$found} {
        return [dict create ok 0 message "that trash entry is no longer in the manifest; nothing written."]
    }
    # v0.20.0: the file is looked for in the current history folder.
    set disk [_rebased_orig $orig]
    if {$disk eq ""} {
        return [dict create ok 0 message "[file tail $orig] is not a history shot file; nothing written."]
    }
    if {![file exists $disk]} {
        return [dict create ok 0 message "[file tail $orig] is not on disk any more; nothing written."]
    }
    if {[dict exists [_reconciled_keys_dict] $key]} {
        return [dict create ok 0 message "already unhidden."]
    }
    set now [clock format [clock seconds] -format {%Y%m%dT%H%M%S}]
    if {[catch {
        set fh [open [reconcile_manifest_path] a]
        fconfigure $fh -encoding utf-8
        puts $fh "$now|$ts|$orig|$batch"
        close $fh
    } err]} {
        if {[info exists fh]} { catch { close $fh } }
        return [dict create ok 0 message "could not write the reconcile manifest: $err"]
    }
    set note ""
    if {![_append_reconcile_log $now $orig $batch]} {
        set note [translate "(its audit line could not be written to delete_log.txt; see the app log)"]
    }
    msg -INFO "ShotHistoryEditor: unhid $orig (trash entry $ts/$batch kept)"
    return [dict create ok 1 message $note]
}

proc ::plugins::ShotHistoryEditor::scroll_reconcile {delta} {
    variable reconcile_offset
    variable reconcile_page_size
    incr reconcile_offset [expr {$delta * $reconcile_page_size}]
    if {$reconcile_offset < 0} { set reconcile_offset 0 }
    refresh_reconcile_page ShotHistoryEditor_reconcile
}

proc ::plugins::ShotHistoryEditor::_reconcile_shown {} {
    variable reconcile_offset
    variable reconcile_page_size
    set records [_reconcile_records]
    set total [llength $records]
    if {$total <= 0} {
        set reconcile_offset 0
    } else {
        set max_offset [expr {(($total - 1) / $reconcile_page_size) * $reconcile_page_size}]
        if {$reconcile_offset > $max_offset} { set reconcile_offset $max_offset }
    }
    if {$reconcile_offset < 0} { set reconcile_offset 0 }
    return [list $total [lrange $records $reconcile_offset [expr {$reconcile_offset + $reconcile_page_size - 1}]]]
}

proc ::plugins::ShotHistoryEditor::refresh_reconcile_page {page} {
    variable reconcile_offset
    variable reconcile_page_size
    variable reconcile_note

    lassign [_reconcile_shown] total shown
    # Status: always at most two lines (the header sits 3 caption lines below).
    if {$total == 0} {
        set status "No hidden shots exist on disk again."
        set hint "Every shot the trash manifest hides is really absent from history/."
    } else {
        set status "Showing [expr {$reconcile_offset + 1}]-[expr {$reconcile_offset + [llength $shown]}] of $total hidden shot(s) that exist on disk again."
        set hint "Unhide puts a shot back in the lists; its trash entry and any trash copy are kept."
    }
    append status "\n" [expr {$reconcile_note ne "" ? $reconcile_note : $hint}]
    catch { dui item config $page reconcile_status -text $status }

    set presence [_sdb_presence [lmap r $shown { dict get $r filename }]]
    for {set i 0} {$i < $reconcile_page_size} {incr i} {
        if {$i < [llength $shown]} {
            set r [lindex $shown $i]
            set fn [dict get $r filename]
            set sdb "not in SDB"
            if {[dict exists $presence $fn]} { set sdb [dict get $presence $fn] }
            set ts [dict get $r ts]
            set deleted_at $ts
            catch { set deleted_at [clock format [clock scan $ts -format {%Y%m%dT%H%M%S}] -format "%Y/%m/%d %H:%M"] }
            if {[dict get $r trash_exists]} {
                set copy "trash copy present (two different files)"
            } else {
                set copy "trash copy missing (stale manifest line)"
            }
            set text "$fn  |  deleted $deleted_at, batch [dict get $r batch]\non disk, modified [_fmt_mtime [dict get $r disk_mtime]]  |  $copy\nSDB: $sdb"
            catch { dui item config $page row${i}_text -text $text }
            catch { dui item show $page row${i}_text }
            catch { dui item show $page row${i}_unhide* -initial 1 }
        } else {
            catch { dui item config $page row${i}_text -text "" }
            catch { dui item hide $page row${i}_text }
            catch { dui item hide $page row${i}_unhide* -initial 1 }
        }
    }
    # v0.13.1: standard pager -- disabled at the ends, never hidden.
    _set_pager_state $page reconcile_prev_page reconcile_next_page \
        [expr {$reconcile_offset > 0}] [expr {$reconcile_offset + [llength $shown] < $total}]
}

proc ::plugins::ShotHistoryEditor::unhide_row {i} {
    variable reconcile_note
    lassign [_reconcile_shown] total shown
    if {$i < 0 || $i >= [llength $shown]} { return }
    set r [lindex $shown $i]
    set result [perform_unhide [dict get $r ts] [dict get $r orig] [dict get $r batch]]
    if {[dict get $result ok]} {
        set reconcile_note "Unhidden [dict get $r filename]: back in the card list and Source Inspector; its trash entry is unchanged."
        if {[dict get $result message] ne ""} { append reconcile_note " " [dict get $result message] }
    } else {
        set reconcile_note "Not unhidden: [dict get $result message]"
    }
    refresh_reconcile_page ShotHistoryEditor_reconcile
}

# Groups manifest records by batch id for the Trash/Restore page. Returns a
# list of dicts: {batch_id ts file_count shot_count shots shot_files}, most
# recent first. v0.14.0 (F6): shot_files pairs each .shot's name (its shot
# timestamp) with the path of its trashed copy, so the card can name it.
proc ::plugins::ShotHistoryEditor::_trash_batches {} {
    array set ts_by_batch {}
    array set files_by_batch {}
    array set shots_by_batch {}
    array set shot_files_by_batch {}
    foreach rec [_manifest_records] {
        set b [dict get $rec batch]
        set ts_by_batch($b) [dict get $rec ts]
        if {![info exists files_by_batch($b)]} { set files_by_batch($b) 0 }
        incr files_by_batch($b)
        set orig [dict get $rec orig]
        if {[string match "*.shot" $orig]} {
            if {![info exists shots_by_batch($b)]} { set shots_by_batch($b) {} }
            set name [file rootname [file tail $orig]]
            lappend shots_by_batch($b) $name
            lappend shot_files_by_batch($b) [list $name [dict get $rec trash]]
        }
    }
    set result {}
    foreach b [array names ts_by_batch] {
        set shots [expr {[info exists shots_by_batch($b)] ? $shots_by_batch($b) : {}}]
        set shot_files [expr {[info exists shot_files_by_batch($b)] ? $shot_files_by_batch($b) : {}}]
        lappend result [dict create batch_id $b ts $ts_by_batch($b) \
            file_count $files_by_batch($b) shot_count [llength $shots] shots $shots \
            shot_files $shot_files]
    }
    return [lsort -command ::plugins::ShotHistoryEditor::_batch_ts_cmp -decreasing $result]
}

# v0.14.0 (F6): the three lines of one Trash card, naming the batch's shot
# rather than the batch. Line 1: the newest shot's own time and bean (+N more
# when the batch holds more); line 2: its grind, dose and yield; line 3: when
# it was deleted, the counts and the batch id (the logs' key). The bean and
# numbers come from the trashed .shot's settings block through the same
# read-only parser the edit flow uses, and only for a path inside the
# plugin's own trash folder -- nothing is written, moved or renamed here.
proc ::plugins::ShotHistoryEditor::_trash_card_lines {b} {
    set files [lsort -index 0 -decreasing [_dget $b shot_files]]
    set n [_dget $b shot_count 0]
    set deleted [_dget $b ts]
    catch { set deleted [_fmt_time [clock scan $deleted -format {%Y%m%dT%H%M%S}]] }
    set files_n [_dget $b file_count 0]
    set line3 "Deleted $deleted   |   $n [expr {$n == 1 ? {shot} : {shots}}], $files_n [expr {$files_n == 1 ? {file} : {files}}]   |   batch [_dget $b batch_id]"
    if {[llength $files] == 0} {
        return [list "No .shot file in this batch" "" $line3]
    }
    set more ""
    if {$n > 1} { set more "   |   +[expr {$n - 1}] more" }
    # The newest shot whose trashed file can be read names the card; if none
    # can, the newest names it and line 2 says why.
    set parsed "" ; set note ""
    foreach f $files {
        lassign $f name path
        if {![_inside_trash_dir $path]} {
            set note "Not read: the file is outside the trash folder."
            continue
        }
        set p [_parse_settings_file $path]
        if {[dict get $p status] eq "found"} { set parsed $p ; break }
        if {$note eq ""} {
            set note [expr {[dict get $p status] eq "missing"
                ? "The trashed shot file is no longer there."
                : "The trashed shot file could not be read."}]
        }
    }
    if {$parsed eq ""} { lassign [lindex $files 0] name path }
    set when $name
    catch { set when [_fmt_time [clock scan $name -format {%Y%m%dT%H%M%S}]] }
    if {$parsed eq ""} {
        return [list "$when$more" $note $line3]
    }
    set v [dict get $parsed values]
    set bean [_bean_label [_dget $v bean_brand] [_dget $v bean_type]]
    if {[string length $bean] > 40} { set bean "[string range $bean 0 36]..." }
    set line1 "$when   |   $bean$more"
    set line2 "Grind [_display [_dget $v grinder_setting]]   Dose [_display [_dget $v grinder_dose_weight]]g   Yield [_display [_dget $v drink_weight]]g"
    return [list $line1 $line2 $line3]
}

proc ::plugins::ShotHistoryEditor::_batch_ts_cmp {a b} {
    return [string compare [dict get $a ts] [dict get $b ts]]
}

# ---------------------------------------------------------------------------
# v0.11.0 -- "Empty trash" PREVIEW. The workspace rule is "never permanent
# deletion" and the verify harness rejects any `file delete`; per the
# destructive-feature process this pass ships the preview stage only: what a
# future Empty trash would remove (batches, files, sizes, ages, totals), with
# the statement that nothing is deleted. Read-only: walks the trash manifest
# and `file size`; writes nothing. A real Empty trash needs the CLAUDE.md
# rule and the harness audit changed first, in its own explicit pass.
# ---------------------------------------------------------------------------

proc ::plugins::ShotHistoryEditor::_fmt_bytes {n} {
    if {$n >= 1048576} { return [format "%.1f MB" [expr {$n / 1048576.0}]] }
    if {$n >= 1024} { return [format "%.1f KB" [expr {$n / 1024.0}]] }
    return "$n B"
}

proc ::plugins::ShotHistoryEditor::empty_trash_preview_text {} {
    set batches [_trash_batches]
    set records [_manifest_records]
    set now [clock seconds]
    set lines [list \
        "Empty trash removes every file in the plugin trash PERMANENTLY. Nothing is removed" \
        "until you tap Empty trash (bottom right) and type the batch count on the confirmation" \
        "page. Restore first anything you might still want; history/ is never touched." \
        ""]
    set empties [_empty_trash_dir_count]
    if {[llength $batches] == 0} {
        lappend lines "The trash is empty: no batches, no files."
        if {$empties > 0} {
            lappend lines "$empties empty batch folder(s) remain under the trash; Tidy on the Trash page removes them."
        }
        return [join $lines "\n"]
    }
    set tot_bytes 0; set tot_files 0; set tot_shots 0; set tot_missing 0
    foreach b $batches {
        set bid [dict get $b batch_id]
        set bytes 0; set present 0; set missing 0
        foreach rec $records {
            if {[dict get $rec batch] ne $bid} { continue }
            set t [dict get $rec trash]
            if {[file isfile $t]} {
                incr present
                catch { incr bytes [file size $t] }
            } else {
                incr missing
            }
        }
        set ts [dict get $b ts]
        set when $ts
        set age "?"
        catch {
            set secs [clock scan $ts -format {%Y%m%dT%H%M%S}]
            set when [clock format $secs -format "%Y/%m/%d %H:%M"]
            set age [expr {($now - $secs) / 86400}]
        }
        set fc [dict get $b file_count]
        set files_note [expr {$missing ? "$present of $fc files present" : "all $fc files present"}]
        lappend lines "$when  |  batch $bid  |  [dict get $b shot_count] shot(s)  |  $files_note  |  [_fmt_bytes $bytes]  |  $age day(s) old"
        incr tot_bytes $bytes
        incr tot_files $present
        incr tot_shots [dict get $b shot_count]
        incr tot_missing $missing
    }
    lappend lines ""
    lappend lines "Would be removed permanently: [llength $batches] batch(es), $tot_shots shot(s), $tot_files file(s), [_fmt_bytes $tot_bytes] under [trash_dir]"
    if {$tot_missing > 0} {
        lappend lines "$tot_missing manifest entr(y/ies) point at files that are already gone (restored, or moved by hand)."
    }
    if {$empties > 0} {
        lappend lines "$empties empty batch folder(s) under the trash (left by earlier restores) would go too; Tidy on the Trash page removes them on their own."
    }
    lappend lines "The trash manifest and delete log would be kept as the audit trail."
    return [join $lines "\n"]
}

# ---------------------------------------------------------------------------
# v0.12.0 -- real Empty trash (the sixth authorized write capability; the
# first permanent deletion, under the CLAUDE.md exception of 2026-09-18).
# The whole write path, in order:
#   1. open_purge_confirm snapshots the batch ids; confirm_purge_submit
#      requires the typed batch count.
#   2. perform_purge refuses if the batch set changed since the snapshot.
#   3. For every trash-manifest line: the trash path must resolve STRICTLY
#      inside SHE's trash/ (plugins/ShotHistoryEditor/trash/, or history_trash/
#      trash/ after the v0.22.0 move) (else kept + logged), must be
#      a listed file (else "already gone", line dropped); then ONE
#      `file delete` on that file. Then `file delete` on each batch folder
#      only if it is now empty (non-empty folders stay).
#   4. Every file gets a line in purge_log.txt (append-only); the trash
#      manifest is rewritten without the removed lines; delete_log.txt gets
#      one PURGE summary line.
# history/, history_v2/ and SDB are never touched by this path.
# ---------------------------------------------------------------------------

proc ::plugins::ShotHistoryEditor::purge_log_path {} {
    return [_she_entry_path purge_log.txt]
}

# True only for a path strictly inside the plugin's own trash folder.
proc ::plugins::ShotHistoryEditor::_inside_trash_dir {path} {
    if {$path eq ""} { return 0 }
    set prefix "[file normalize [trash_dir]]/"
    set p [file normalize $path]
    return [expr {[string length $p] > [string length $prefix] &&
                  [string equal -length [string length $prefix] $prefix $p]}]
}

# 1 when the line is on disk. v0.22.0: write-ahead -- a file gets its
# "removing" line BEFORE it is deleted, and no line means no delete
# (CLAUDE.md: every removed file has a purge_log.txt line).
proc ::plugins::ShotHistoryEditor::_append_purge_line {ts rec bytes status} {
    return [_she_append [purge_log_path] \
        "$ts|[dict get $rec batch]|[dict get $rec orig]|[dict get $rec trash]|$bytes|$status"]
}

proc ::plugins::ShotHistoryEditor::perform_purge {expected_batch_ids} {
    set why [_she_write_blocker]
    if {$why ne ""} {
        return [dict create ok 0 message "Nothing was removed: $why." \
            batches 0 removed_files 0 bytes 0 skipped {} already_gone 0 manifest_ok 1 log_failed 0 log_ok 1]
    }
    set ts [clock format [clock seconds] -format {%Y%m%dT%H%M%S}]
    set batches [_trash_batches]
    set ids [lsort [lmap b $batches { dict get $b batch_id }]]
    if {$ids ne [lsort $expected_batch_ids]} {
        return [dict create ok 0 message "The trash changed since the preview; nothing was removed. Open the preview again." \
            batches 0 removed_files 0 bytes 0 skipped {} already_gone 0 manifest_ok 1]
    }
    if {[llength $batches] == 0} {
        return [dict create ok 0 message "The trash is empty; nothing to remove." \
            batches 0 removed_files 0 bytes 0 skipped {} already_gone 0 manifest_ok 1]
    }
    # v0.23.2: the manifest read whole or not at all -- a failed read used to
    # look empty, and the rewrite below then emptied the manifest.
    set rd [_manifest_read [trash_manifest_path] 1]
    if {![dict get $rd ok]} {
        return [dict create ok 0 message "The trash manifest cannot be read ([dict get $rd err]); nothing was removed." \
            batches 0 removed_files 0 bytes 0 skipped {} already_gone 0 manifest_ok 1 log_failed 0 log_ok 1]
    }
    set removed 0
    set bytes 0
    set already_gone 0
    set log_failed 0
    set skipped {}
    set keep {}
    foreach line [dict get $rd lines] {
        set parts [split $line "|"]
        # A line that is not ts|orig|trash|batch names no file: kept as it is.
        if {[llength $parts] != 4} { lappend keep $line ; continue }
        lassign $parts lts lorig ltrash lbatch
        set rec [dict create ts $lts orig $lorig trash $ltrash batch $lbatch]
        set t [dict get $rec trash]
        if {![_inside_trash_dir $t]} {
            lappend skipped [dict create path $t reason "outside the plugin trash folder"]
            lappend keep $line
            if {![_append_purge_line $ts $rec 0 "SKIPPED outside trash"]} { incr log_failed }
            continue
        }
        if {![file isfile $t]} {
            incr already_gone
            if {![_append_purge_line $ts $rec 0 "already gone"]} { incr log_failed }
            continue
        }
        set sz 0
        catch { set sz [file size $t] }
        # v0.22.0: write-ahead -- no purge_log line, no delete.
        if {![_append_purge_line $ts $rec $sz "removing"]} {
            lappend skipped [dict create path $t reason "kept: its purge_log.txt line could not be written"]
            lappend keep $line
            incr log_failed
            continue
        }
        if {[catch { file delete -- $t } err]} {   ;# purge-only (CLAUDE.md exception 2026-09-18)
            lappend skipped [dict create path $t reason "could not remove: $err"]
            lappend keep $line
            if {![_append_purge_line $ts $rec $sz "FAILED $err"]} { incr log_failed }
            continue
        }
        incr removed
        incr bytes $sz
        if {![_append_purge_line $ts $rec $sz "removed"]} { incr log_failed }
    }
    # v0.13.0: every empty folder directly under the trash goes, not only
    # the ones this purge emptied (earlier restores left theirs behind).
    set folders_removed [_remove_empty_trash_dirs]
    set manifest_ok [_manifest_write $keep]
    set log_ok [_she_append [delete_log_path] \
        "$ts PURGE batches=[llength $batches] files_removed=$removed bytes=$bytes folders_removed=$folders_removed already_gone=$already_gone skipped=[llength $skipped] manifest_rewritten=$manifest_ok purge_log_failures=$log_failed (Empty trash)"]
    msg -NOTICE "ShotHistoryEditor: Empty trash removed $removed file(s), $bytes bytes, [llength $batches] batch(es), $folders_removed empty folder(s); skipped [llength $skipped]"
    return [dict create ok 1 message "" batches [llength $batches] removed_files $removed bytes $bytes \
        skipped $skipped already_gone $already_gone manifest_ok $manifest_ok folders_removed $folders_removed \
        log_failed $log_failed log_ok $log_ok]
}

# ---------------------------------------------------------------------------
# v0.13.0 -- empty trash folders. Restore moves files out of a batch folder
# but never removed the folder, so the tablet had 14 empty ones. This sweep
# removes every EMPTY folder directly under the plugin trash (the ONLY folder
# `file delete` in the plugin, guarded by _inside_trash_dir; a folder holding
# anything at all stays). Shared by Empty trash and Tidy (Trash page).
# ---------------------------------------------------------------------------

proc ::plugins::ShotHistoryEditor::_empty_trash_dirs {} {
    set root [trash_dir]
    # v0.15.2 (review): precondition, not catch -- glob throws on a folder it
    # cannot list (-nocomplain only covers "no match"), and since F18 the
    # Trash page counts on every refresh. A folder that cannot be listed
    # cannot be proven empty, so it stays: this only narrows what Tidy and
    # Empty trash may remove.
    if {![file isdirectory $root] || ![file readable $root]} { return {} }
    set out {}
    foreach d [lsort [glob -nocomplain -directory $root -types d *]] {
        if {![_inside_trash_dir $d]} { continue }
        if {![file readable $d]} { continue }
        set left [lsearch -all -inline -not -regexp [glob -nocomplain -directory $d -tails * .*] {^\.\.?$}]
        if {[llength $left] == 0} { lappend out $d }
    }
    return $out
}

proc ::plugins::ShotHistoryEditor::_empty_trash_dir_count {} {
    return [llength [_empty_trash_dirs]]
}

proc ::plugins::ShotHistoryEditor::_remove_empty_trash_dirs {} {
    set removed 0
    foreach d [_empty_trash_dirs] {
        if {[catch { file delete -- $d } err]} {   ;# purge-only (CLAUDE.md exception 2026-09-18)
            msg -NOTICE "ShotHistoryEditor: could not remove the empty trash folder $d: $err"
        } else {
            incr removed
        }
    }
    return $removed
}

# v0.15.2 (F18): the Trash page's Tidy button names what it would remove --
# "Tidy N empty folders" -- and is greyed out while there is nothing to tidy
# (dui's enable_or_disable: a hidden page is left alone). The count and the
# number in the label are not part of the translated words.
proc ::plugins::ShotHistoryEditor::_refresh_tidy_btn {page} {
    set n [llength [_empty_trash_dirs]]
    if {$n == 0} {
        set lbl [translate "Tidy empty folders"]
    } elseif {$n == 1} {
        set lbl "[translate Tidy] 1 [translate {empty folder}]"
    } else {
        set lbl "[translate Tidy] $n [translate {empty folders}]"
    }
    catch { dui item config $page tidy -label $lbl }
    # -initial 1 (review): the state survives the next page load too, so a
    # greyed Tidy is drawn grey from the first frame instead of flashing.
    catch { dui item enable_or_disable [expr {$n > 0}] $page tidy* -initial 1 }
}

# Trash page > Tidy (v0.15.2; was Advanced > Tidy since v0.13.0): folders
# only, files and batches untouched; one audit line.
proc ::plugins::ShotHistoryEditor::tidy_trash_folders {} {
    variable tidy_note
    set why [_she_write_blocker]
    if {$why ne ""} {
        set tidy_note "Tidy did not run: $why."
        refresh_trash_page ShotHistoryEditor_trash
        return
    }
    set n [_remove_empty_trash_dirs]
    set ts [clock format [clock seconds] -format {%Y%m%dT%H%M%S}]
    set logged [_she_append [delete_log_path] "$ts TIDY removed $n empty trash folder(s)"]
    msg -INFO "ShotHistoryEditor: Tidy removed $n empty trash folder(s)"
    set tidy_note "Tidy: removed $n empty trash folder(s); files and batches untouched."
    if {!$logged} { append tidy_note " (delete_log.txt could not be written; see the app log)" }
    refresh_trash_page ShotHistoryEditor_trash
}

proc ::plugins::ShotHistoryEditor::refresh_advanced_page {page} {
    set n [deleted_shot_count]
    set r [reconcile_count]
    set note ""
    if {$n > 0} {
        set note "$n deleted shot(s) hidden (SDB not modified; it may resync on its own)."
    }
    if {$r > 0} {
        append note [expr {$note eq "" ? "" : " "}] "$r of them exist on disk again - see Reconcile hidden shots."
    }
    # v0.22.0: while SHE's own files are mid-move or in two places, every
    # write is refused; say why where the tools are.
    set why [_she_write_blocker]
    if {$why ne ""} { set note "Nothing can be written now: $why." }
    catch { dui item config $page deleted_note -text $note }
}

proc ::plugins::ShotHistoryEditor::open_purge_confirm {} {
    variable purge_batch_ids
    variable purge_input
    variable purge_error
    set purge_batch_ids [lmap b [_trash_batches] { dict get $b batch_id }]
    if {[llength $purge_batch_ids] == 0} { return }
    set purge_input ""
    set purge_error ""
    open_page ShotHistoryEditor_purge_confirm
}

proc ::plugins::ShotHistoryEditor::cancel_purge_confirm {} {
    _return_to_page ShotHistoryEditor_empty_preview
}

proc ::plugins::ShotHistoryEditor::refresh_purge_confirm_page {page} {
    variable purge_batch_ids
    variable purge_error
    set n [llength $purge_batch_ids]
    catch { dui item config $page purge_instructions -text \
        "Type $n (the number of trash batches) below, then tap Remove permanently. Every file in the plugin trash is deleted for good; this cannot be undone. history/ is not touched." }
    catch { dui item config $page purge_error_text -text $purge_error }
}

# The one place that calls perform_purge.
proc ::plugins::ShotHistoryEditor::confirm_purge_submit {} {
    variable purge_batch_ids
    variable purge_input
    variable purge_error
    variable purge_result_text
    set n [llength $purge_batch_ids]
    set typed [string trim $purge_input]
    if {$n == 0 || $typed ne [expr {$n}]} {
        set purge_error "Type exactly \"$n\" to confirm. Nothing was removed."
        refresh_purge_confirm_page ShotHistoryEditor_purge_confirm
        return
    }
    set result [perform_purge $purge_batch_ids]
    set lines [list]
    if {[dict get $result ok]} {
        lappend lines "Removed [dict get $result removed_files] file(s) ([_fmt_bytes [dict get $result bytes]]) from [dict get $result batches] trash batch(es), permanently."
        if {[dict get $result already_gone] > 0} {
            lappend lines "[dict get $result already_gone] manifest entr(y/ies) pointed at files that were already gone."
        }
        if {[dict get $result folders_removed] > 0} {
            lappend lines "Removed [dict get $result folders_removed] empty batch folder(s)."
        }
        if {![dict get $result manifest_ok]} {
            lappend lines "WARNING: the trash manifest could not be rewritten; see the log."
        }
        if {[_dget $result log_failed 0] > 0 || ![_dget $result log_ok 1]} {
            lappend lines "WARNING: [_dget $result log_failed 0] purge_log.txt line(s) and the delete_log summary ([_pick [_dget $result log_ok 1] written {NOT written}]) -- see the app log."
        }
    } else {
        lappend lines "Not removed: [dict get $result message]"
    }
    set skipped [dict get $result skipped]
    if {[llength $skipped] > 0} {
        lappend lines ""
        lappend lines "Kept (not removed):"
        foreach s $skipped { lappend lines "  [dict get $s path]: [dict get $s reason]" }
    }
    lappend lines ""
    lappend lines "Audit: purge_log.txt (one line per file) and delete_log.txt. history/ and SDB were not touched."
    set purge_result_text [join $lines "\n"]
    open_page ShotHistoryEditor_purge_result
}

proc ::plugins::ShotHistoryEditor::refresh_purge_result_page {page} {
    variable purge_result_text
    catch { dui item config $page purge_result_text -text $purge_result_text }
}

# Back to the Trash page, whose show{} refreshes the (now emptier) list.
proc ::plugins::ShotHistoryEditor::close_purge_result {} {
    _return_to_page ShotHistoryEditor_trash
}

# Moves history/<filename>.shot and (if present) history_v2/<filename>.json
# for each filename into a new trash batch folder. Uses `file rename` only --
# never `file delete`. If any single file fails to move, the WHOLE batch
# stops immediately; files already moved before the failure are still
# recorded in the manifest (so nothing moved is ever left untracked) and
# reported back as moved, alongside the failure.
proc ::plugins::ShotHistoryEditor::perform_delete_batch {filenames} {
    set batch_id [_new_batch_id]
    set ts [clock format [clock seconds] -format {%Y%m%dT%H%M%S}]
    set why [_she_write_blocker]
    if {$why ne ""} {
        return [dict create ok 0 message "Nothing was deleted: $why." \
            moved_files 0 shot_count 0 failed {} batch_id $batch_id trash_path "" log_ok 1]
    }
    set batch_dir [file join [trash_dir] "${ts}_${batch_id}"]
    set moved {}
    set failed {}
    set shot_count 0

    if {[catch { file mkdir $batch_dir } err]} {
        # v0.23.3: the same shape as every other return (the result page
        # read trash_path and each failed entry's filename/reason, and threw).
        msg -ERROR "ShotHistoryEditor: could not create the trash folder $batch_dir: $err"
        return [dict create ok 0 message "Nothing was deleted: the trash folder could not be made ($err)." \
            moved_files 0 shot_count 0 batch_id $batch_id trash_path $batch_dir log_ok 1 \
            failed [lmap fn $filenames { dict create filename $fn reason "not moved: no trash folder" }]]
    }
    # v0.22.0: the manifest must take this batch's lines before anything
    # moves (opening it to append creates it if needed and writes nothing).
    if {[catch { close [open [trash_manifest_path] a] } err]} {
        msg -ERROR "ShotHistoryEditor: the trash manifest cannot be written: $err"
        return [dict create ok 0 message "Nothing was deleted: the trash manifest cannot be written ($err)." \
            moved_files 0 shot_count 0 failed {} batch_id $batch_id trash_path $batch_dir log_ok 1]
    }
    # v0.23.2: and read whole, since the batch's lines are added to all of it.
    set rd [_manifest_read [trash_manifest_path]]
    if {![dict get $rd ok]} {
        return [dict create ok 0 message "Nothing was deleted: the trash manifest cannot be read ([dict get $rd err])." \
            moved_files 0 shot_count 0 failed {} batch_id $batch_id trash_path $batch_dir log_ok 1]
    }

    foreach fn $filenames {
        if {![_safe_filename $fn]} {
            lappend failed [dict create filename $fn reason "unsafe filename"]
            continue
        }
        set legacy_src [_legacy_file $fn]
        set json_src [_json_file $fn]
        set pair {}
        if {[file isfile $legacy_src]} {
            lappend pair [list $legacy_src [file join $batch_dir [file tail $legacy_src]]]
        }
        if {[file isfile $json_src]} {
            lappend pair [list $json_src [file join $batch_dir [file tail $json_src]]]
        }
        if {[llength $pair] == 0} {
            lappend failed [dict create filename $fn reason "no matching history/history_v2 files found"]
            continue
        }

        set pair_moved {}
        set move_err ""
        foreach p $pair {
            lassign $p src dst
            if {[catch { file rename -- $src $dst } err]} {
                set move_err $err
                break
            }
            lappend pair_moved [list $fn $src $dst]
        }

        if {$move_err ne ""} {
            # Stop the whole batch here; keep whatever already succeeded.
            foreach pm $pair_moved { lappend moved $pm }
            lappend failed [dict create filename $fn reason "move failed: $move_err"]
            set logged [_append_manifest_and_log $moved $batch_id $ts $shot_count]
            if {![dict get $logged manifest_ok]} {
                return [_delete_unrecorded $moved $batch_id $batch_dir $shot_count $failed]
            }
            # Some files DID move before the stop, so the history folder has
            # changed and the recommendation is stale even though this batch
            # failed. Refresh on exactly that condition (v0.6.3).
            set note ""
            if {[llength $moved] > 0} {
                set note [_notify_downstream "a partial delete"]
            }
            return [dict create ok 0 message "A file move failed partway through the batch; stopped." \
                moved_files [llength $moved] shot_count $shot_count failed $failed batch_id $batch_id \
                trash_path $batch_dir refresh_note $note log_ok [dict get $logged log_ok]]
        }

        foreach pm $pair_moved { lappend moved $pm }
        incr shot_count
    }

    set logged [_append_manifest_and_log $moved $batch_id $ts $shot_count]
    if {![dict get $logged manifest_ok]} {
        return [_delete_unrecorded $moved $batch_id $batch_dir $shot_count $failed]
    }

    # v0.6.3: the deleted shots must stop counting towards the grind
    # recommendation. Once per batch, after the manifest is written -- never
    # per file, and never before, so a batch that moved nothing asks SDB for
    # nothing.
    set note ""
    if {[llength $moved] > 0} {
        set note [_notify_downstream "the delete"]
    }
    return [dict create ok 1 message "" moved_files [llength $moved] shot_count $shot_count \
        failed $failed batch_id $batch_id trash_path $batch_dir refresh_note $note \
        log_ok [dict get $logged log_ok]]
}

# v0.22.0: the batch's files moved but its manifest lines could not be
# written -- without them nothing would know where the files went, so they
# go back to history/ (and history_v2/). Anything that cannot go back is
# named on the result page and in the app log.
proc ::plugins::ShotHistoryEditor::_delete_unrecorded {moved batch_id batch_dir shot_count failed} {
    set stuck [_delete_put_back $moved]
    set back [expr {[llength $moved] - [llength $stuck]}]
    if {[llength $stuck]} {
        msg -ERROR "ShotHistoryEditor: delete batch $batch_id: the trash manifest could not be written and [llength $stuck] file(s) could not be put back: [join $stuck {, }]"
        set m "The trash manifest could not be written. $back file(s) went back to history/; [llength $stuck] could not and are still in $batch_dir: [join $stuck {, }]."
    } else {
        msg -ERROR "ShotHistoryEditor: delete batch $batch_id: the trash manifest could not be written; all $back file(s) were put back"
        set m "The trash manifest could not be written, so nothing was deleted: all $back file(s) are back in history/."
    }
    # Only files that stayed out of history/ change what Grind Advisor sees.
    if {[llength $stuck]} { _notify_downstream "a delete that could not be put back" }
    return [dict create ok 0 message $m moved_files [llength $stuck] shot_count 0 failed $failed \
        batch_id $batch_id trash_path $batch_dir refresh_note "" log_ok 0 put_back $back stuck $stuck]
}

# Moves every file in a trash batch back to its original path. Move only --
# never overwrites. If the original path already has a file (name
# collision), that file is skipped and left in the trash/manifest so it can
# be retried later rather than silently lost.
# v0.20.0: the target is the record's name in the CURRENT history folder
# (_rebased_orig), never the stored absolute path, and the source must be
# inside the plugin trash; a record failing either is kept and counted as
# refused. Refused, collided and a failed manifest rewrite are reported on
# the Trash page (note) and in delete_log's RESTORE line; refusals and a
# failed rewrite also go to the app log (-NOTICE). v0.22.0: refused while a
# move of SHE's files is unfinished or they are in two places; a RESTORE
# line that cannot be written is named in the note.
proc ::plugins::ShotHistoryEditor::restore_batch {batch_id} {
    set why [_she_write_blocker]
    if {$why ne ""} {
        return [dict create restored 0 collisions 0 refused 0 manifest_ok 1 refresh_note "" \
            trash_note "Restore did not run: $why."]
    }
    # v0.23.2: the manifest read whole or not at all -- a failed read used to
    # look empty, and the rewrite below then emptied the manifest.
    set rd [_manifest_read [trash_manifest_path] 1]
    if {![dict get $rd ok]} {
        return [dict create restored 0 collisions 0 refused 0 failed 0 manifest_ok 1 refresh_note "" \
            trash_note "Restore did not run: the trash manifest cannot be read ([dict get $rd err]); nothing was moved."]
    }
    # v0.23.3: a batch the manifest does not name is refused before anything
    # moves (a stale card, or a manifest read that came back short).
    set mine 0
    foreach line [dict get $rd lines] {
        set parts [split $line "|"]
        if {[llength $parts] == 4 && [lindex $parts 3] eq $batch_id} { incr mine }
    }
    if {$mine == 0} {
        msg -ERROR "ShotHistoryEditor: restore: batch $batch_id is not in [trash_manifest_path]"
        return [dict create restored 0 collisions 0 refused 0 failed 0 manifest_ok 1 refresh_note "" \
            trash_note "Restore did not run: batch $batch_id is not in the trash manifest; nothing was moved."]
    }
    set keep {}
    set restored 0
    set collisions 0
    set refused 0
    set failed 0

    foreach line [dict get $rd lines] {
        set parts [split $line "|"]
        # A line that is not ts|orig|trash|batch names no file: kept as it is.
        if {[llength $parts] != 4} { lappend keep $line ; continue }
        lassign $parts lts lorig ltrash lbatch
        set rec [dict create ts $lts orig $lorig trash $ltrash batch $lbatch]
        if {[dict get $rec batch] ne $batch_id} {
            lappend keep $line
            continue
        }
        set trash [dict get $rec trash]
        if {![_inside_trash_dir $trash]} {
            incr refused
            lappend keep $line
            continue
        }
        if {![file isfile $trash]} {
            # Nothing left to restore for this line; drop it from the manifest.
            continue
        }
        set orig [_rebased_orig [dict get $rec orig] $trash]
        if {$orig eq ""} {
            incr refused
            lappend keep $line
            continue
        }
        if {[file exists $orig]} {
            incr collisions
            lappend keep $line
            continue
        }
        # v0.23.2: a folder or rename failure is its own count, with its
        # reason in the app log (it was counted as "already in history").
        set err ""
        if {![file isdirectory [file dirname $orig]] && [catch { file mkdir [file dirname $orig] } err]} {
            msg -ERROR "ShotHistoryEditor: restore: could not make [file dirname $orig]: $err"
        } elseif {[catch { file rename -- $trash $orig } err]} {
            msg -ERROR "ShotHistoryEditor: restore: $trash not moved back to $orig: $err"
        } else {
            set err ""
        }
        if {$err ne ""} {
            incr failed
            lappend keep $line
        } else {
            incr restored
            # v0.7.1: stamp the restored file's modification time -- the
            # same mechanism the edit path has used since v0.6.0, for the
            # same reason. `file rename` preserves the original mtime, and
            # SDB's populate only re-reads a file whose mtime is NEWER than
            # the one it stored. Normally that is harmless (the row already
            # matches the file), but if the path was rewritten while the
            # shot sat in trash -- seen for real on 2026-08-24, when the
            # core's flush-save bug parked a corpse under a restored shot's
            # name -- SDB has stored the REWRITE's metadata, and the
            # restored original's older mtime stops it from ever being
            # re-read. Stamping makes the resync (which _notify_downstream
            # triggers right after this loop) pick up the restored truth
            # unconditionally.
            if {[catch { file mtime $orig [clock seconds] } err]} {
                catch { msg -NOTICE "ShotHistoryEditor: could not stamp the modification time of $orig: $err (SDB may keep older metadata for this shot until it is resynced another way)" }
            }
        }
    }

    # v0.23.3: a restore that drops no line (every file kept, collided or
    # refused) leaves the manifest as it is: nothing to rewrite.
    if {[llength $keep] == [llength [dict get $rd lines]]} {
        set manifest_ok 1
        set rewritten unchanged
    } else {
        set manifest_ok [_manifest_write $keep]
        set rewritten $manifest_ok
    }
    set log_ok [_append_restore_log $batch_id $restored $collisions $refused $rewritten $failed]
    if {!$manifest_ok} {
        msg -NOTICE "ShotHistoryEditor: restore of batch $batch_id moved $restored file(s) back but could not rewrite [trash_manifest_path]"
    }
    if {$refused > 0} {
        msg -NOTICE "ShotHistoryEditor: restore of batch $batch_id refused $refused manifest record(s) (outside the trash folder, or not a history file name)"
    }

    # v0.6.3: the same gap in reverse. A restored shot must start counting
    # again -- SDB's populate clears `removed` for a file that has reappeared,
    # so this needs no special handling beyond asking for the resync.
    set note ""
    if {$restored > 0} {
        set note [_notify_downstream "the restore"]
    }
    set trash_note [_restore_problem_note $restored $collisions $refused $manifest_ok $failed]
    if {!$log_ok} {
        if {$trash_note eq ""} { set trash_note "Restore: $restored file(s) back." }
        append trash_note " delete_log.txt could not be written; see the app log."
    }
    return [dict create restored $restored collisions $collisions refused $refused failed $failed \
        manifest_ok $manifest_ok refresh_note $note log_ok $log_ok trash_note $trash_note]
}

# v0.20.0: the Trash page's one-line report of a restore that did not simply
# work ("" when it did: the batch's card just goes away, as before).
proc ::plugins::ShotHistoryEditor::_restore_problem_note {restored collisions refused manifest_ok {failed 0}} {
    set parts {}
    if {$collisions > 0} { lappend parts "$collisions kept (that name is already in history)" }
    if {$failed > 0} { lappend parts "$failed could not be moved back (see the log)" }
    if {$refused > 0} { lappend parts "$refused refused (not a trash file or a history name)" }
    if {!$manifest_ok} { lappend parts "the trash list could not be rewritten (see the log)" }
    if {[llength $parts] == 0} { return "" }
    return "Restore: $restored file(s) back; [join $parts {; }]."
}

# v0.8.2: idempotent. Every reader closes the handle when done and
# _open_ro_db closes it again before opening, so the old bare
# `catch { $db_handle close }` failed on every open; catch swallowed the
# error but left $::errorInfo dirty, and the core BLE runner prints
# $::errorInfo (de1_comms.tcl:120) -- surfaced as "BLE error info invalid
# command name ..." (first seen in MaintenanceTracker v0.21.2). Closing
# only an existing command raises nothing.
proc ::plugins::ShotHistoryEditor::_close_db {} {
    variable db_handle
    if {[llength [info commands $db_handle]]} {
        if {[catch { $db_handle close } err]} {
            catch { msg "ShotHistoryEditor: SDB close failed: $err" }
        }
    }
}

proc ::plugins::ShotHistoryEditor::_open_ro_db {} {
    variable db_handle
    variable last_error
    set last_error ""
    set path [sdb_path]

    if {![file isfile $path]} {
        set last_error "SDB database not found: $path"
        return ""
    }
    if {![llength [info commands sqlite3]]} {
        set last_error "sqlite3 package is not available."
        return ""
    }

    _close_db
    if {[catch { sqlite3 $db_handle $path -readonly true } err]} {
        set last_error "Could not open SDB read-only: $err"
        return ""
    }
    return $db_handle
}

proc ::plugins::ShotHistoryEditor::_q {name} {
    set escaped [string map [list "\"" "\"\""] $name]
    return "\"$escaped\""
}

proc ::plugins::ShotHistoryEditor::_tables_views {db} {
    set objects {}
    catch {
        $db eval {SELECT name, type FROM sqlite_master
                  WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'
                  ORDER BY type, name} row {
            lappend objects [dict create name $row(name) type $row(type)]
        }
    }
    return $objects
}

proc ::plugins::ShotHistoryEditor::_object_exists {objects name} {
    foreach item $objects {
        if {[dict get $item name] eq $name} { return 1 }
    }
    return 0
}

proc ::plugins::ShotHistoryEditor::_columns {db table} {
    set cols {}
    catch {
        $db eval "PRAGMA table_info([_q $table])" row {
            lappend cols $row(name)
        }
    }
    return $cols
}

proc ::plugins::ShotHistoryEditor::_has_col {cols col} {
    return [expr {[lsearch -exact $cols $col] >= 0}]
}

proc ::plugins::ShotHistoryEditor::_select_expr {cols col alias} {
    if {[_has_col $cols $col]} {
        return "[_q $col] AS [_q $alias]"
    }
    return "NULL AS [_q $alias]"
}

proc ::plugins::ShotHistoryEditor::_choose_source {db} {
    variable detected_objects
    variable table_used

    set detected_objects [_tables_views $db]
    if {[_object_exists $detected_objects V_shot]} {
        set table_used V_shot
        return V_shot
    }
    if {[_object_exists $detected_objects shot]} {
        set table_used shot
        return shot
    }
    set table_used ""
    return ""
}

proc ::plugins::ShotHistoryEditor::_fmt_time {clock_value} {
    if {$clock_value eq ""} { return "" }
    if {![string is integer -strict $clock_value]} { return $clock_value }
    if {[catch { clock format $clock_value -format "%Y/%m/%d %H:%M" } out]} {
        return $clock_value
    }
    return $out
}

proc ::plugins::ShotHistoryEditor::_dget {dict_value key {default ""}} {
    if {[catch { dict exists $dict_value $key } exists]} { return $default }
    if {$exists} { return [dict get $dict_value $key] }
    return $default
}

proc ::plugins::ShotHistoryEditor::_display {value} {
    if {$value eq ""} { return "-" }
    return $value
}

proc ::plugins::ShotHistoryEditor::_bean_label {brand type} {
    set text [string trim "$brand $type"]
    if {$text eq ""} { return "-" }
    return $text
}

proc ::plugins::ShotHistoryEditor::scrolling_support_text {} {
    return "enabled: paged scrolling with fixed navigation buttons"
}

proc ::plugins::ShotHistoryEditor::_page_count {text} {
    variable page_line_count
    set n [llength [split $text "\n"]]
    if {$n <= 0} { return 1 }
    set pages [expr {int(ceil(double($n) / double($page_line_count)))}]
    if {$pages < 1} { set pages 1 }
    return $pages
}

proc ::plugins::ShotHistoryEditor::_paged_text {text page_index} {
    variable page_line_count
    set lines [split $text "\n"]
    set pages [_page_count $text]
    if {$page_index < 0} { set page_index 0 }
    if {$page_index >= $pages} { set page_index [expr {$pages - 1}] }
    set start [expr {$page_index * $page_line_count}]
    set finish [expr {$start + $page_line_count - 1}]
    return [list [join [lrange $lines $start $finish] "\n"] $page_index $pages]
}

proc ::plugins::ShotHistoryEditor::_set_paged_text {dui_page text_tag status_tag text index_var {pager 0}} {
    upvar #0 ::plugins::ShotHistoryEditor::$index_var page_index
    lassign [_paged_text $text $page_index] shown page_index pages
    catch { dui item config $dui_page $text_tag -text $shown }
    catch { dui item config $dui_page $status_tag -text "Page [expr {$page_index + 1}] of $pages" }
    # v0.13.1: pages carrying the standard pager (prev_page / next_page)
    # disable its unavailable end; delete_review has no pager.
    if {$pager} {
        _set_pager_state $dui_page prev_page next_page \
            [expr {$page_index > 0}] [expr {$page_index < $pages - 1}]
    }
}

proc ::plugins::ShotHistoryEditor::scroll_page {kind delta dui_page} {
    switch -- $kind {
        detail {
            variable detail_page_index
            incr detail_page_index $delta
            _set_paged_text $dui_page detail_text detail_page_status [build_detail_text] detail_page_index 1
        }
        diagnostics {
            variable diagnostics_page_index
            incr diagnostics_page_index $delta
            _set_paged_text $dui_page diagnostics_text diagnostics_page_status [diagnostics_text] diagnostics_page_index 1
        }
        help {
            # v0.19.1: Help pages by help_pages (explicit breaks). Its
            # paragraphs wrap to several rows, so the shared 22-line count
            # said "1 of 1" while the text ran under the bottom bar.
            variable help_page_index
            set pages [help_pages]
            set n [llength $pages]
            incr help_page_index $delta
            if {$help_page_index < 0} { set help_page_index 0 }
            if {$help_page_index >= $n} { set help_page_index [expr {$n - 1}] }
            catch { dui item config $dui_page help_text -text [lindex $pages $help_page_index] }
            catch { dui item config $dui_page help_page_status -text "Page [expr {$help_page_index + 1}] of $n" }
            _set_pager_state $dui_page prev_page next_page \
                [expr {$help_page_index > 0}] [expr {$help_page_index < $n - 1}]
        }
        delete_review {
            variable delete_review_page_index
            incr delete_review_page_index $delta
            _set_paged_text $dui_page review_text review_page_status [build_delete_review_text] delete_review_page_index
        }
        empty_preview {
            variable empty_preview_page_index
            incr empty_preview_page_index $delta
            _set_paged_text $dui_page empty_preview_text empty_preview_page_status [empty_trash_preview_text] empty_preview_page_index 1
        }
        migrate_preview {
            variable migrate_preview_page_index
            incr migrate_preview_page_index $delta
            # v0.22.0: a file that vanishes mid-count or a folder that cannot
            # be listed must not break the page: logged and shown instead.
            if {[catch { migrate_preview_text } txt]} {
                msg -ERROR "ShotHistoryEditor: the Move page could not be built: $txt"
                set txt "The Move page could not be built: $txt\nNothing was moved. See the app log."
            }
            _set_paged_text $dui_page migrate_preview_text migrate_preview_page_status $txt migrate_preview_page_index 1
        }
    }
}

proc ::plugins::ShotHistoryEditor::load_recent_shots {} {
    variable recent_rows
    variable max_recent
    variable last_error

    set recent_rows {}
    set db [_open_ro_db]
    if {$db eq ""} { return $recent_rows }

    set table [_choose_source $db]
    if {$table eq ""} {
        set last_error "No SDB shot table or V_shot view detected."
        _close_db
        return $recent_rows
    }

    set cols [_columns $db $table]
    # v0.17.0: file_modification_date retires bag-save overlays (_apply_edit_overlay).
    set aliases {clock filename profile_title grinder_setting grinder_dose_weight drink_weight bean_brand bean_type espresso_notes extraction_time removed file_modification_date}
    set select_parts {}
    foreach alias $aliases {
        lappend select_parts [_select_expr $cols $alias $alias]
    }

    set sql "SELECT [join $select_parts {, }] FROM [_q $table]"
    if {[_has_col $cols removed]} {
        append sql " WHERE (removed IS NULL OR removed=0)"
    }
    if {[_has_col $cols clock]} {
        append sql " ORDER BY [_q clock] DESC"
    } elseif {[_has_col $cols filename]} {
        append sql " ORDER BY [_q filename] DESC"
    }
    # SDB has no idea about soft-deleted shots (it is never modified), so
    # this scans more rows than needed and filters/truncates in Tcl below.
    append sql " LIMIT [expr {$max_recent + 200}]"

    set deleted [_deleted_filenames_dict]
    set overlays [_all_edit_overlays]
    if {[catch {
        $db eval $sql row {
            if {[dict exists $deleted $row(filename)]} { continue }
            set item {}
            foreach a $aliases {
                dict set item $a $row($a)
            }
            dict set item table_used $table
            set item [_apply_edit_overlay $item $overlays]
            lappend recent_rows $item
            if {[llength $recent_rows] >= $max_recent} { break }
        }
    } err]} {
        set last_error "Could not read recent shots: $err"
    }

    _close_db
    return $recent_rows
}

proc ::plugins::ShotHistoryEditor::_legacy_file {filename} {
    if {$filename eq ""} { return "" }
    if {[string match "*.shot" $filename]} {
        return [file join [history_path] $filename]
    }
    return [file join [history_path] "$filename.shot"]
}

proc ::plugins::ShotHistoryEditor::_json_file {filename} {
    if {$filename eq ""} { return "" }
    if {[string match "*.json" $filename]} {
        return [file join [history_v2_path] $filename]
    }
    return [file join [history_v2_path] "$filename.json"]
}

proc ::plugins::ShotHistoryEditor::_clean_value {value} {
    set value [string trim $value]
    if {$value eq "{}"} { return "" }
    return $value
}

# Pass 5.0 refactor note: this used to be the whole body of
# read_legacy_settings, inlined against a path computed from a filename.
# Extracted unchanged (byte-for-byte same parsing logic) so the save path's
# verification step (perform_metadata_edit) can run the identical, proven
# reader against an arbitrary path (a temp file, or the real file after
# rename) without needing a filename that resolves through _legacy_file.
# read_legacy_settings's own behavior/signature is completely unchanged.
proc ::plugins::ShotHistoryEditor::_parse_settings_file {path} {
    set wanted {bean_brand bean_type grinder_setting grinder_dose_weight drink_weight espresso_notes my_name drinker_name}
    set result [dict create status missing path $path values {} message ""]
    if {$path eq "" || ![file isfile $path]} {
        dict set result message "Matching legacy .shot file not found."
        return $result
    }

    if {[catch {
        set fh [open $path r]
        fconfigure $fh -encoding utf-8
        set in_settings 0
        set values {}
        while {[gets $fh line] >= 0} {
            set trimmed [string trim $line]
            if {!$in_settings} {
                # Pass 5.0 finding: comparing against the literal string
                # "settings {" (unescaped) here previously only survived
                # Tcl's source-time brace-matching by accident, because this
                # proc's total brace count is coincidentally balanced by the
                # "}" comparison a few lines below -- but at RUNTIME, once
                # this comparison actually executes against a real
                # "settings {" line, Tcl's expression evaluator throws
                # "invalid character '}' in expression". This was never
                # triggered by this plugin's own tests before, since those
                # only used single-line synthetic settings{} fixtures where
                # this exact line was never reached with a matching value.
                # Escaping the brace (\{) fixes the runtime error without
                # changing what this comparison matches.
                if {$trimmed eq "settings \{"} {
                    set in_settings 1
                }
                continue
            }
            if {$trimmed eq "\}"} {
                break
            }
            if {$trimmed eq ""} { continue }
            # v0.14.0: skip a line that is not a complete Tcl list BEFORE
            # lindex can fail on it -- a real .shot's settings block holds a
            # read_only_backup line that opens a brace it closes lines later,
            # and the caught lindex error left errorInfo dirty, which the core
            # prints as a "BLE error info" line (de1_comms.tcl:120). The Trash
            # cards parse up to five files per refresh. Same lines skipped.
            # (No literal braces in this comment: they would unbalance the
            # proc body, see the Pass 5.0 note above.)
            if {![info complete $trimmed]} { continue }
            if {[catch {
                set key [lindex $trimmed 0]
                set val [_clean_value [join [lrange $trimmed 1 end] " "]]
            }]} {
                continue
            }
            if {[lsearch -exact $wanted $key] >= 0} {
                dict set values $key $val
            }
        }
        close $fh
    } err]} {
        catch { close $fh }
        dict set result status error
        dict set result message "Could not read legacy .shot settings block: $err"
        return $result
    }

    if {![info exists in_settings] || !$in_settings} {
        dict set result status error
        dict set result message "No settings block found in legacy .shot file."
        return $result
    }
    dict set result status found
    dict set result values $values
    return $result
}

proc ::plugins::ShotHistoryEditor::read_legacy_settings {filename} {
    return [_parse_settings_file [_legacy_file $filename]]
}

proc ::plugins::ShotHistoryEditor::_selected_filename {} {
    variable selected_row
    if {$selected_row eq ""} { return "" }
    return [_dget $selected_row filename]
}

proc ::plugins::ShotHistoryEditor::_field_kind {field} {
    if {[lsearch -exact {grinder_setting grinder_dose_weight drink_weight} $field] >= 0} {
        return numeric
    }
    return text
}

proc ::plugins::ShotHistoryEditor::_editable_field_count {values} {
    variable editable_fields
    set n 0
    foreach field $editable_fields {
        if {[_dget $values $field] ne ""} { incr n }
    }
    return $n
}

proc ::plugins::ShotHistoryEditor::_selected_source_info {} {
    set filename [_selected_filename]
    if {$filename eq ""} {
        return [dict create filename "" shot_exists "not selected" json_exists "not selected" editable_count "not selected"]
    }
    set legacy_path [_legacy_file $filename]
    set json_path [_json_file $filename]
    set legacy_info [read_legacy_settings $filename]
    set values [_dget $legacy_info values]
    return [dict create \
        filename $filename \
        shot_exists [expr {[file isfile $legacy_path] ? "yes" : "no"}] \
        json_exists [expr {[file isfile $json_path] ? "yes" : "no"}] \
        editable_count [_editable_field_count $values]]
}

proc ::plugins::ShotHistoryEditor::open_edit_preview {{return_page ShotHistoryEditor_settings}} {
    variable edit_new_value
    variable edit_preview_text
    variable edit_warning
    variable edit_return_page
    set edit_return_page $return_page
    set edit_new_value ""
    set edit_preview_text "No change previewed yet."
    set edit_warning ""
    open_page ShotHistoryEditor_edit_preview
}

# v0.5.0: switched from open_page to _return_to_page. Edit Preview can be
# entered from Settings (1 level deep) or from Shot Detail (up to 4 levels
# deep), and the new Save/Confirm/Result mini-flow hangs another 2 pages off
# of this same page -- exactly the class of dialog-stack bug fixed in
# v0.4.1 (see CLAUDE.md's "Dialog navigation" rule). Using the proven
# close_dialog + corrective load pattern here up front avoids shipping
# another copy of that bug in the very flow being extended.
proc ::plugins::ShotHistoryEditor::back_from_edit_preview {} {
    variable edit_return_page
    _return_to_page $edit_return_page
}

proc ::plugins::ShotHistoryEditor::cycle_edit_field {} {
    variable editable_fields
    variable edit_field
    set idx [lsearch -exact $editable_fields $edit_field]
    if {$idx < 0} { set idx 0 }
    set idx [expr {($idx + 1) % [llength $editable_fields]}]
    set edit_field [lindex $editable_fields $idx]
    set ::plugins::ShotHistoryEditor::edit_preview_text "Preview only - no files will be modified."
    set ::plugins::ShotHistoryEditor::edit_warning ""
    refresh_edit_preview_page ShotHistoryEditor_edit_preview
}

proc ::plugins::ShotHistoryEditor::_current_edit_value {} {
    variable edit_field
    set filename [_selected_filename]
    if {$filename eq ""} { return "" }
    set legacy_info [read_legacy_settings $filename]
    set values [_dget $legacy_info values]
    return [_dget $values $edit_field]
}

proc ::plugins::ShotHistoryEditor::preview_change {} {
    variable edit_field
    variable edit_new_value
    variable edit_preview_text
    variable edit_warning

    set old_value [_current_edit_value]
    set new_value [string trim $edit_new_value]
    set edit_warning ""

    if {[_field_kind $edit_field] eq "numeric" && ![string is double -strict $new_value]} {
        set edit_warning "Warning: $edit_field should be numeric. This is still preview only."
    }
    # v0.23.0: say now what Save would refuse.
    set vp [_bag_value_problem $edit_field $new_value]
    if {$vp ne ""} { set edit_warning "This value cannot be saved: $edit_field $vp." }

    # v0.23.0: compact (the text sits above the bottom bar), plus what a
    # later version would change in history_v2 -- shown, never written.
    set fn [_selected_filename]
    # At most 8 caption rows fit above the bottom bar: one row per line, so
    # long values are cut (the full value is on the page above).
    set shown {}
    foreach v [list [_display $old_value] [_display $new_value]] {
        if {[string length $v] > 90} { set v "[string range $v 0 86]..." }
        lappend shown $v
    }
    set lines [list \
        "Preview only -- tap Save Change below to write this." \
        "Before: $edit_field = [lindex $shown 0]" \
        "After: $edit_field = [lindex $shown 1]" \
        "Save writes only history/$fn.shot (that one settings line); SDB is never written."]
    if {$fn ne "" && $new_value ne ""} {
        lappend lines {*}[_v2_preview_lines [v2_preview $fn [list $edit_field $new_value]]]
    }
    set edit_preview_text [join $lines "\n"]
    refresh_edit_preview_page ShotHistoryEditor_edit_preview
}

# ---------------------------------------------------------------------------
# v0.5.0 -- real metadata save confirmation flow: Save Change (on Edit
# Preview) -> Confirm (Before/After + danger Save Change button) -> Result
# -> back to edit_return_page. Cancel at Confirm and Done at Result both use
# _return_to_page (see back_from_edit_preview's note above for why).
# ---------------------------------------------------------------------------

proc ::plugins::ShotHistoryEditor::open_edit_confirm {} {
    variable edit_field
    variable edit_new_value
    variable edit_confirm_filename
    variable edit_confirm_field
    variable edit_confirm_old_value
    variable edit_confirm_new_value

    set filename [_selected_filename]
    if {$filename eq ""} { return }
    set new_value [string trim $edit_new_value]
    if {$new_value eq ""} { return }

    set edit_confirm_filename $filename
    set edit_confirm_field $edit_field
    set edit_confirm_old_value [_current_edit_value]
    set edit_confirm_new_value $new_value
    open_page ShotHistoryEditor_edit_confirm
}

proc ::plugins::ShotHistoryEditor::cancel_edit_confirm {} {
    _return_to_page ShotHistoryEditor_edit_preview
}

proc ::plugins::ShotHistoryEditor::refresh_edit_confirm_page {page} {
    variable edit_confirm_filename
    variable edit_confirm_field
    variable edit_confirm_old_value
    variable edit_confirm_new_value

    set warning ""
    if {[_field_kind $edit_confirm_field] eq "numeric" && ![string is double -strict $edit_confirm_new_value]} {
        set warning "Warning: $edit_confirm_field is usually numeric."
    }
    set vp [_bag_value_problem $edit_confirm_field $edit_confirm_new_value]
    if {$vp ne ""} { set warning "This value cannot be saved: $edit_confirm_field $vp." }

    catch { dui item config $page confirm_shot_text -text "Shot: $edit_confirm_filename" }
    catch { dui item config $page confirm_file_text -text "File: history/$edit_confirm_filename.shot" }
    catch { dui item config $page confirm_field_text -text "Field: $edit_confirm_field" }
    catch { dui item config $page confirm_before_text -text "Before: [_display $edit_confirm_old_value]" }
    catch { dui item config $page confirm_after_text -text "After: [_display $edit_confirm_new_value]" }
    catch { dui item config $page confirm_warning_text -text $warning }

    # v0.23.0: one line on history_v2 (the detail is on Edit Preview).
    # v0.23.2: last, after the page's own texts.
    set v2 ""
    if {$edit_confirm_filename ne ""} {
        set pv [v2_preview $edit_confirm_filename [list $edit_confirm_field $edit_confirm_new_value]]
        switch -- [dict get $pv status] {
            none { set v2 "history_v2: no copy of this shot; nothing to update." }
            ok {
                if {[dict get $pv check] eq ""} {
                    set v2 "history_v2: this Save also changes [llength [dict get $pv edits]] value(s) in its copy, after a checked backup (see Edit Preview)."
                } else {
                    set v2 "history_v2: this Save leaves it as it is ([dict get $pv check])."
                }
            }
            default { set v2 "history_v2: this Save leaves it as it is ([dict get $pv message])." }
        }
    }
    catch { dui item config $page confirm_v2_text -text $v2 }
}

# The one place this pass authorizes a real write. Everything up to here is
# navigation/preview; tapping Save Change here is the only path that ever
# calls perform_metadata_edit.
proc ::plugins::ShotHistoryEditor::confirm_save_submit {} {
    variable edit_confirm_filename
    variable edit_confirm_field
    variable edit_confirm_new_value
    variable edit_result_text

    set result [perform_metadata_edit $edit_confirm_filename $edit_confirm_field $edit_confirm_new_value]
    set lines [list]
    if {[dict get $result ok]} {
        lappend lines "Saved. $edit_confirm_field for $edit_confirm_filename was updated."
        lappend lines "Before: [_display [dict get $result old_value]]"
        lappend lines "After: [_display [dict get $result new_value]]"
    } else {
        lappend lines "Not saved: [dict get $result message]"
    }
    if {[dict get $result ok] && ![_dget $result log_ok 1]} {
        lappend lines "WARNING: edit_manifest.txt or edit_log.txt could not be written (see the app log); the card list may show the old value until SDB resyncs."
    }
    lappend lines ""
    lappend lines "Backup: [dict get $result backup_path]"
    lappend lines ""
    # v0.6.0: the file's modification time is stamped on a successful save, so
    # SDB's own resync can finally see the edit -- before this, an edited shot
    # kept the timestamp it was first written with and SDB skipped it forever.
    # Grind Advisor is refreshed straight afterwards when it is installed.
    # v0.24.0: what happened to the shot's history_v2 copy.
    if {[dict exists $result v2]} {
        lappend lines [_v2_result_line [dict get $result v2]]
    } else {
        lappend lines "history_v2 is unchanged."
    }
    # v0.23.3: no catch -- a failed save has no refresh_note, and a caught
    # error leaves errorInfo dirty for the next core error line.
    set note [_dget $result refresh_note ""]
    if {$note ne ""} {
        lappend lines "Grind Advisor: $note"
    } else {
        lappend lines "SDB is not written to directly; the card list overlays this correction until SDB resyncs."
    }
    set edit_result_text [join $lines "\n"]

    open_page ShotHistoryEditor_edit_result
}

proc ::plugins::ShotHistoryEditor::refresh_edit_result_page {page} {
    variable edit_result_text
    catch { dui item config $page edit_result_text -text $edit_result_text }
}

proc ::plugins::ShotHistoryEditor::close_edit_result {} {
    variable edit_return_page
    _return_to_page $edit_return_page
}

proc ::plugins::ShotHistoryEditor::refresh_edit_preview_page {page} {
    variable selected_row
    variable edit_field
    variable edit_new_value
    variable edit_preview_text
    variable edit_warning

    set filename [_selected_filename]
    if {$filename eq ""} {
        set selected_text "No shot selected."
        set source_text "Editable source: none"
        set current_value ""
    } else {
        set selected_text "Selected shot: $filename | [_fmt_time [_dget $selected_row clock]]"
        set source_text "Editable source: history/$filename.shot settings block"
        set current_value [_current_edit_value]
    }

    set field_text "$edit_field ([_field_kind $edit_field])"
    set status_text "Tap Preview Change to see Before/After, then Save Change to write it (and its history_v2 copy). SDB is never written."
    if {$edit_warning ne ""} { append status_text "\n$edit_warning" }

    catch { dui item config $page selected_shot -text $selected_text }
    catch { dui item config $page editable_source -text $source_text }
    catch { dui item config $page field_value -text $field_text }
    catch { dui item config $page current_value -text [_display $current_value] }
    catch { dui item config $page preview_text -text $edit_preview_text }
    catch { dui item config $page preview_status -text $status_text }
}

proc ::plugins::ShotHistoryEditor::_json_meta_value {meta path} {
    set cur $meta
    foreach key $path {
        if {[catch { dict exists $cur $key } exists] || !$exists} {
            return ""
        }
        set cur [dict get $cur $key]
    }
    return $cur
}

proc ::plugins::ShotHistoryEditor::read_history_v2_meta {filename} {
    set path [_json_file $filename]
    set result [dict create status missing path $path values {} message ""]
    if {$path eq "" || ![file isfile $path]} {
        dict set result message "Matching history_v2 JSON file not found."
        return $result
    }
    if {![llength [info commands ::json::json2dict]]} {
        dict set result status error
        dict set result message "json package is not available."
        return $result
    }

    if {[catch {
        set fh [open $path r]
        fconfigure $fh -encoding utf-8
        set raw [read $fh]
        close $fh
        set obj [::json::json2dict $raw]
        if {![dict exists $obj meta]} {
            error "meta block missing"
        }
        set meta [dict get $obj meta]
        set values [dict create \
            bean_brand [_json_meta_value $meta {bean brand}] \
            bean_type [_json_meta_value $meta {bean type}] \
            bean_notes [_json_meta_value $meta {bean notes}] \
            roast_level [_json_meta_value $meta {bean roast_level}] \
            roast_date [_json_meta_value $meta {bean roast_date}] \
            espresso_notes [_json_meta_value $meta {shot notes}] \
            espresso_enjoyment [_json_meta_value $meta {shot enjoyment}] \
            drink_tds [_json_meta_value $meta {shot tds}] \
            drink_ey [_json_meta_value $meta {shot ey}] \
            grinder_model [_json_meta_value $meta {grinder model}] \
            grinder_setting [_json_meta_value $meta {grinder setting}] \
            grinder_dose_weight [_json_meta_value $meta {in}] \
            drink_weight [_json_meta_value $meta {out}] \
            extraction_time [_json_meta_value $meta {time}]]
    } err]} {
        catch { close $fh }
        dict set result status error
        dict set result message "Could not read history_v2 meta block: $err"
        return $result
    }

    dict set result status found
    dict set result values $values
    return $result
}

# ---------------------------------------------------------------------------
# v0.23.0 -- history_v2 update PREVIEW (John, de1app PR #373 point 3: an
# edited shot's history_v2/<ts>.json keeps the old values). Nothing here
# writes. For an edit it finds, in the .json text, the value of each v2 path
# the field lives at, says what a later version would put there, and checks
# the result in memory: re-read with ::json::json2dict, only those values
# may differ. Owner decisions 2026-10-21: only the fields being edited, a
# shot without a .json is left alone (as SDB does), no backfill of earlier
# edits. Never the core converter (shot::convert_legacy_to_v2) or SDB's
# sync_v2_shot_file: both fill an old shot's raw arrays from the live shot.
# ---------------------------------------------------------------------------

# The v2 paths of a .shot settings field: its meta value (if it has one)
# and app.data.settings.<field>, the copy of ::settings the app saved.
proc ::plugins::ShotHistoryEditor::_v2_paths {field} {
    switch -- $field {
        bean_brand          { set m {meta bean brand} }
        bean_type           { set m {meta bean type} }
        bean_notes          { set m {meta bean notes} }
        roast_level         { set m {meta bean roast_level} }
        roast_date          { set m {meta bean roast_date} }
        espresso_notes      { set m {meta shot notes} }
        grinder_setting     { set m {meta grinder setting} }
        grinder_dose_weight { set m {meta in} }
        drink_weight        { set m {meta out} }
        default             { set m "" }
    }
    set out {}
    if {$m ne ""} { lappend out $m }
    lappend out [list app data settings $field]
    return $out
}

# The value tokens at the given key paths: path -> list of {start end}
# (character indices into text). One regexp pass splits the JSON into
# strings, structural characters and bare values; a key stack follows the
# objects (arrays are walked, never matched).
proc ::plugins::ShotHistoryEditor::_v2_find {text paths} {
    set re [string map [list Q [format %c 34] B [format %c 92]] {Q(?:[^QBB]|BB.)*Q|[{}\[\],:]|[^\s{}\[\],:Q]+}]
    set toks [regexp -all -indices -inline -- $re $text]
    set stack {}
    set pending ""
    set found [dict create]
    set n [llength $toks]
    for {set i 0} {$i < $n} {incr i} {
        lassign [lindex $toks $i] s e
        set c [string index $text $s]
        if {$c eq "\{" || $c eq "\["} {
            lappend stack [list $c $pending]
            set pending ""
        } elseif {$c eq "\}" || $c eq "\]"} {
            set stack [lrange $stack 0 end-1]
            set pending ""
        } elseif {$c eq ","} {
            set pending ""
        } elseif {$c ne ":"} {
            if {[lindex $stack end 0] eq "\{" && $pending eq "" && $i + 1 < $n &&
                [string index $text [lindex $toks [expr {$i + 1}] 0]] eq ":"} {
                set pending [_json_unquote [string range $text $s $e]]
                continue
            }
            if {$pending ne ""} {
                set path {}
                foreach fr [lrange $stack 1 end] { lappend path [lindex $fr 1] }
                lappend path $pending
                if {$path in $paths} { dict lappend found $path [list $s $e] }
                set pending ""
            }
        }
    }
    return $found
}

# A JSON string token -> its text. Every JSON escape is also a Tcl
# backslash escape, and only those are substituted.
proc ::plugins::ShotHistoryEditor::_json_unquote {tok} {
    return [subst -nocommands -novariables [string range $tok 1 end-1]]
}

# Text -> a JSON string token in the app's own style (huddle's jsondump:
# backslash, quote, slash, newline, tab, CR, backspace, form feed escaped;
# any other control character as a 4-digit hex escape; other characters as
# they are, the file being UTF-8).
proc ::plugins::ShotHistoryEditor::_json_quote {s} {
    set bs [format %c 92]
    set q [format %c 34]
    set s [string map [list $bs $bs$bs $q $bs$q / $bs/ \n ${bs}n \t ${bs}t \r ${bs}r \
        [format %c 8] ${bs}b [format %c 12] ${bs}f] $s]
    set out ""
    foreach ch [split $s ""] {
        scan $ch %c code
        if {$code < 32} { append out [format "%cu%04x" 92 $code] } else { append out $ch }
    }
    return "$q$out$q"
}

# The patched text for changes (a list of field value pairs), in memory.
# Returns ok, message, edits (field path old new for each v2 value) and
# text. Refuses a path that is missing or found twice, or whose value is not
# a JSON string (every value in the app's own files is one).
proc ::plugins::ShotHistoryEditor::_v2_patch_text {text changes} {
    set want {}
    foreach {field value} $changes {
        foreach p [_v2_paths $field] { lappend want [list $p $field $value] }
    }
    set found [_v2_find $text [lmap w $want { lindex $w 0 }]]
    set edits {} ; set spans {}
    foreach w $want {
        lassign $w p field value
        set label [join $p .]
        set hits {}
        if {[dict exists $found $p]} { set hits [dict get $found $p] }
        if {[llength $hits] != 1} {
            return [dict create ok 0 message "$label [_pick [llength $hits] {appears more than once} {is not in the file}]" edits {} text ""]
        }
        lassign [lindex $hits 0] s e
        set tok [string range $text $s $e]
        if {[string index $tok 0] ne [format %c 34]} {
            return [dict create ok 0 message "$label is not a text value" edits {} text ""]
        }
        lappend edits [dict create field $field path $p old [_json_unquote $tok] new $value]
        lappend spans [list $s $e [_json_quote $value]]
    }
    foreach sp [lsort -integer -decreasing -index 0 $spans] {
        lassign $sp s e tok
        set text [string replace $text $s $e $tok]
    }
    return [dict create ok 1 message "" edits $edits text $text]
}

# "" when after re-reads as before with only the edits' values changed, else
# why not. Needs tcllib's json (the app has it; Source Inspector uses it).
proc ::plugins::ShotHistoryEditor::_v2_verify {before after edits} {
    if {![llength [info commands ::json::json2dict]]} { return "not checked: the json package is missing" }
    if {[catch { set a [::json::json2dict $after] } err]} { return "the patched file would not read back: $err" }
    if {[catch { set b [::json::json2dict $before] } err]} { return "the file does not read: $err" }
    foreach ed $edits {
        set p [dict get $ed path]
        if {[catch { dict get $a {*}$p } v] || $v ne [dict get $ed new]} { return "[join $p .] would not read back as the new value" }
        # The same set on both sides, so both are rebuilt the same way and
        # compare as strings only by their content.
        dict set b {*}$p [dict get $ed new]
        dict set a {*}$p [dict get $ed new]
    }
    if {$a ne $b} { return "something else in the file would change" }
    return ""
}

# The preview for one shot and its changes (field value pairs): status
# none (no .json: left alone), ok (edits, check), refused (why), error.
proc ::plugins::ShotHistoryEditor::v2_preview {filename changes} {
    set path [_json_file $filename]
    set res [dict create status none path $path edits {} check "" message ""]
    if {$path eq "" || ![file isfile $path]} {
        dict set res message "no history_v2 copy of this shot; nothing to update"
        return $res
    }
    if {[catch {
        set fh [open $path r]
        fconfigure $fh -encoding utf-8
        set text [read $fh]
        close $fh
    } err]} {
        if {[info exists fh]} { catch { close $fh } }
        return [dict merge $res [dict create status error message "could not read it: $err"]]
    }
    # v0.23.2: a file the scanner or the check cannot handle is an error
    # status for the page, logged, never an error thrown into it.
    if {[catch {
        set p [_v2_patch_text $text $changes]
        if {[dict get $p ok]} { set chk [_v2_verify $text [dict get $p text] [dict get $p edits]] }
    } err]} {
        msg -ERROR "ShotHistoryEditor: history_v2 preview of $path failed: $err"
        return [dict merge $res [dict create status error message "could not check it: $err"]]
    }
    if {![dict get $p ok]} {
        return [dict merge $res [dict create status refused message [dict get $p message]]]
    }
    return [dict merge $res [dict create status ok edits [dict get $p edits] check $chk]]
}

# Bag Review's history_v2 sentence: how many of the files Save would change
# have a copy (left as they are by this version; a later one updates the
# changed fields). "" when no file changes.
proc ::plugins::ShotHistoryEditor::_bag_v2_note {files} {
    set have 0 ; set of 0
    foreach f $files {
        if {[dict get $f status] ne "change"} { continue }
        incr of
        if {[file isfile [_json_file [dict get $f filename]]]} { incr have }
    }
    if {$of == 0} { return "" }
    return " history_v2: $have [translate of] $of [translate {have a copy; Save updates the changed fields there too.}]"
}

# The preview as text lines for a page (values cut to max characters).
# v0.23.2: every line fits one caption row (row characters): each value's
# share shrinks with its path label, and any longer line is cut.
proc ::plugins::ShotHistoryEditor::_v2_preview_lines {pv {max 40} {row 120}} {
    set name [file tail [dict get $pv path]]
    switch -- [dict get $pv status] {
        none    { set lines [list "history_v2: [dict get $pv message]."] }
        refused { set lines [list "history_v2/$name: Save leaves it as it is ([dict get $pv message])."] }
        error   { set lines [list "history_v2/$name: [dict get $pv message]; Save leaves it as it is."] }
        default {
            set lines [list "history_v2/$name -- Save changes these values too (backed up and checked first):"]
            foreach ed [dict get $pv edits] {
                set label [join [dict get $ed path] .]
                set m [expr {min($max, max(8, ($row - [string length $label] - 12) / 2))}]
                set o [string map {\n " " \r " " \t " "} [dict get $ed old]]
                set n [string map {\n " " \r " " \t " "} [dict get $ed new]]
                foreach v {o n} { if {[string length [set $v]] > $m} { set $v "[string range [set $v] 0 [expr {$m - 4}]]..." } }
                set q [format %c 34]
                lappend lines "  $label: $q$o$q -> $q$n$q"
            }
            set chk [dict get $pv check]
            if {$chk eq ""} {
                lappend lines "  Checked: it would read back with only these [llength [dict get $pv edits]] values changed."
            } else {
                lappend lines "  Save leaves it as it is: $chk."
            }
        }
    }
    set out {}
    foreach l $lines {
        set l [string map {\n " " \r " "} $l]
        if {[string length $l] > $row} { set l "[string range $l 0 [expr {$row - 4}]]..." }
        lappend out $l
    }
    return $out
}

# ---------------------------------------------------------------------------
# v0.24.0 -- the FIRST history_v2 WRITE (WRITE CAPABILITY 10; John, de1app PR
# #373 point 3; owner decision 2026-10-21). After a .shot write that has been
# made, verified and logged -- the single-field Save and every file of a bag
# Save -- the same field(s) are changed in the shot's history_v2/<ts>.json:
# only the mapped string values (_v2_paths: the meta value and
# app.data.settings.<field>), never an array, a sensor series or anything
# else; never the core converter. Order, each step checked:
#   1  the .json read as bytes (plain UTF-8 only), patched in memory
#      (_v2_patch_text), the result re-read with tcllib json (_v2_verify:
#      only those values differ) -- else SKIPPED, nothing written
#   2  backup into the save's own backups/ folder, byte for byte
#   3  V2 BEGIN in edit_log.txt (write-ahead: no line, no write)
#   4  temp file in that backup folder, read back byte for byte, verified
#   5  one rename over the .json; read back byte for byte
#   6  a failed rename or read-back: the backup copied back and checked
#      (_bag_restore); RESTORE_FAILED names the intact copy
# A v2 result never rolls back or stops the .shot write; the result pages
# and edit_log.txt (V2 OK | UNCHANGED | ABSENT | SKIPPED | FAILED |
# RESTORE_FAILED) say what happened. A shot without a .json is left alone.
# ---------------------------------------------------------------------------

# A path directly inside the current history_v2 folder.
proc ::plugins::ShotHistoryEditor::_inside_history_v2_dir {path} {
    set root [file normalize [history_v2_path]]
    set p [file normalize $path]
    return [expr {[string first "$root/" $p] == 0 && [file dirname $p] eq $root}]
}

# One shot's .json. changes: field value pairs; backup_dir: the save's
# backup folder (exists, inside backups/). Returns dict status (ok,
# unchanged, absent, skipped, failed, restore_failed), reason, path,
# backup, edits. Only _v2_save calls it.
proc ::plugins::ShotHistoryEditor::_v2_write {ts filename changes backup_dir} {
    set path [_json_file $filename]
    set out [dict create status absent reason "" path $path backup "" edits {}]
    if {$path eq "" || ![file isfile $path]} {
        dict set out reason "no history_v2 copy"
        return $out
    }
    if {![_inside_history_v2_dir $path] || ![_inside_backups_dir [file join $backup_dir x]]} {
        return [dict merge $out [dict create status failed reason "a path left its folder; nothing written"]]
    }
    if {[catch { _read_bytes $path } raw]} {
        return [dict merge $out [dict create status skipped reason "could not read it ($raw)"]]
    }
    set text [encoding convertfrom utf-8 $raw]
    if {[encoding convertto utf-8 $text] ne $raw} {
        return [dict merge $out [dict create status skipped reason "not plain UTF-8; left as it is"]]
    }
    set p [_v2_patch_text $text $changes]
    if {![dict get $p ok]} {
        return [dict merge $out [dict create status skipped reason [dict get $p message]]]
    }
    dict set out edits [dict get $p edits]
    set chk [_v2_verify $text [dict get $p text] [dict get $p edits]]
    if {$chk ne ""} {
        return [dict merge $out [dict create status skipped reason $chk]]
    }
    set bytes [encoding convertto utf-8 [dict get $p text]]
    if {$bytes eq $raw} {
        return [dict merge $out [dict create status unchanged reason "it already holds these values"]]
    }
    set backup [file join $backup_dir "$filename.json"]
    set tmp [file join $backup_dir "$filename.json.new"]
    dict set out backup $backup
    if {[file exists $backup] || [file exists $tmp]} {
        return [dict merge $out [dict create status failed reason "its backup name is taken; nothing written"]]
    }
    if {[catch { file copy -- $path $backup } err] || [_read_bytes_or_empty $backup] ne $raw} {
        return [dict merge $out [dict create status failed reason "the backup did not check out; nothing written"]]
    }
    set fields [lsort -unique [lmap e [dict get $p edits] { dict get $e field }]]
    if {![_she_append [edit_log_path] "$ts V2 BEGIN file=[file tail $path] fields=[join $fields ,] backup=$backup"]} {
        return [dict merge $out [dict create status failed reason "edit_log.txt could not be written; nothing written"]]
    }
    if {[catch { _write_bytes $tmp $bytes } err]} {
        return [dict merge $out [dict create status failed reason "temp file not written ($err); the .json untouched"]]
    }
    if {[_read_bytes_or_empty $tmp] ne $bytes ||
        [_v2_verify $text [encoding convertfrom utf-8 [_read_bytes_or_empty $tmp]] [dict get $p edits]] ne ""} {
        return [dict merge $out [dict create status failed reason "temp file did not read back; the .json untouched"]]
    }
    if {[catch { file rename -force -- $tmp $path } err]} {
        if {[_read_bytes_or_empty $path] eq $raw} {
            return [dict merge $out [dict create status failed reason "not renamed into place ($err); the .json untouched"]]
        }
        return [dict merge $out [_bag_restore $path $backup $raw "rename failed ($err)"]]
    }
    if {[_read_bytes_or_empty $path] ne $bytes} {
        return [dict merge $out [_bag_restore $path $backup $raw "the written .json did not read back"]]
    }
    return [dict merge $out [dict create status ok reason ""]]
}

# The one caller of _v2_write: runs it (an error inside is a FAILED result,
# never an error thrown into the save), writes its edit_log line and returns
# its result plus log_ok.
proc ::plugins::ShotHistoryEditor::_v2_save {ts filename changes backup_dir} {
    if {[catch { _v2_write $ts $filename $changes $backup_dir } r]} {
        msg -ERROR "ShotHistoryEditor: history_v2 write of $filename stopped by an error: $r"
        set r [dict create status failed reason "stopped by an error: $r" path [_json_file $filename] backup "" edits {}]
    }
    set name [file tail [dict get $r path]]
    set fields [join [lsort -unique [lmap e [dict get $r edits] { dict get $e field }]] ,]
    set reason [_esc [dict get $r reason]]
    switch -- [dict get $r status] {
        ok             { set line "V2 OK file=$name fields=$fields values=[llength [dict get $r edits]] backup=[dict get $r backup]" }
        unchanged      { set line "V2 UNCHANGED file=$name fields=$fields" }
        absent         { set line "V2 ABSENT file=$filename.json (no history_v2 copy; left alone)" }
        skipped        { set line "V2 SKIPPED file=$name reason=$reason" }
        restore_failed { set line "V2 RESTORE_FAILED file=$name intact_copy=[dict get $r backup] reason=$reason" }
        default        { set line "V2 FAILED file=$name reason=$reason" }
    }
    switch -- [dict get $r status] {
        failed - restore_failed { msg -ERROR "ShotHistoryEditor: $line" }
        skipped { msg -NOTICE "ShotHistoryEditor: $line" }
    }
    dict set r log_ok [_she_append [edit_log_path] "$ts $line"]
    return $r
}

# One line for a result page about one shot's history_v2 copy.
proc ::plugins::ShotHistoryEditor::_v2_result_line {r} {
    set name "history_v2/[file tail [dict get $r path]]"
    switch -- [dict get $r status] {
        ok        { set s "$name: updated too ([llength [dict get $r edits]] value(s); backed up and checked)." }
        unchanged { set s "$name: already held the new value; not written." }
        absent    { set s "history_v2: no copy of this shot; nothing to update." }
        skipped   { set s "$name: left as it is ([dict get $r reason]); the .shot change stands." }
        restore_failed { set s "$name: the write went wrong and could NOT be put back; the intact copy is [dict get $r backup]. The .shot change stands." }
        default   { set s "$name: NOT updated ([dict get $r reason]); the .shot change stands." }
    }
    if {![_dget $r log_ok 1]} { append s " Its edit_log.txt line could not be written." }
    return $s
}

proc ::plugins::ShotHistoryEditor::_norm {value} {
    set value [string trim $value]
    if {$value eq "" || $value eq "-"} { return "" }
    if {[string is double -strict $value]} {
        set out [format %.4f [expr {double($value)}]]
        regsub {0+$} $out "" out
        regsub {\.$} $out "" out
        return $out
    }
    return [string tolower $value]
}

proc ::plugins::ShotHistoryEditor::_status {values} {
    set normalized {}
    set missing 0
    foreach v $values {
        set n [_norm $v]
        if {$n eq ""} {
            set missing 1
        } else {
            lappend normalized $n
        }
    }
    if {[llength $normalized] == 0 || $missing} { return "missing" }
    set first [lindex $normalized 0]
    foreach n $normalized {
        if {$n ne $first} { return "differs" }
    }
    return "match"
}

proc ::plugins::ShotHistoryEditor::_comparison_lines {sdb legacy json_values} {
    set lines [list "Comparison:"]
    foreach item {
        {Grind grinder_setting grinder_setting grinder_setting}
        {Dose grinder_dose_weight grinder_dose_weight grinder_dose_weight}
        {Yield drink_weight drink_weight drink_weight}
        {Bean bean_pair bean_pair bean_pair}
        {Notes espresso_notes espresso_notes espresso_notes}
        {Shot_time extraction_time {} extraction_time}
    } {
        lassign $item label sdb_key legacy_key json_key
        if {$sdb_key eq "bean_pair"} {
            set sv [_bean_label [_dget $sdb bean_brand] [_dget $sdb bean_type]]
            set hv [_bean_label [_dget $legacy bean_brand] [_dget $legacy bean_type]]
            set jv [_bean_label [_dget $json_values bean_brand] [_dget $json_values bean_type]]
        } else {
            set sv [_dget $sdb $sdb_key]
            if {$legacy_key eq ""} {
                set hv ""
            } else {
                set hv [_dget $legacy $legacy_key]
            }
            set jv [_dget $json_values $json_key]
        }
        lappend lines "$label: SDB=[_display $sv] | history=[_display $hv] | history_v2=[_display $jv] | status=[_status [list $sv $hv $jv]]"
    }
    return $lines
}

proc ::plugins::ShotHistoryEditor::build_detail_text {} {
    variable selected_row
    if {$selected_row eq ""} {
        return "No shot selected."
    }

    # v0.5.0: overlay any saved edits onto the SDB-sourced fields so the
    # "SDB:" section below reflects the correction immediately, even though
    # SDB itself is never written to. Uses a separate local variable
    # (display_row) since `selected_row` above is `variable`-linked to the
    # namespace variable -- assigning to it directly would overwrite the
    # real stored selection with overlaid values.
    set display_row [_apply_edit_overlay $selected_row [_all_edit_overlays]]

    set filename [_dget $display_row filename]
    set legacy_info [read_legacy_settings $filename]
    set json_info [read_history_v2_meta $filename]
    set legacy_values [_dget $legacy_info values]
    set json_values [_dget $json_info values]

    set lines [list \
        "SDB:" \
        "filename / id: [_display $filename] / [_display [_dget $display_row clock]]" \
        "date/time: [_display [_fmt_time [_dget $display_row clock]]]" \
        "profile: [_display [_dget $display_row profile_title]]" \
        "grinder_setting: [_display [_dget $display_row grinder_setting]]" \
        "grinder_dose_weight: [_display [_dget $display_row grinder_dose_weight]]" \
        "drink_weight: [_display [_dget $display_row drink_weight]]" \
        "bean_brand: [_display [_dget $display_row bean_brand]]" \
        "bean_type: [_display [_dget $display_row bean_type]]" \
        "espresso_notes: [_display [_dget $display_row espresso_notes]]" \
        "shot time: [_display [_dget $display_row extraction_time]]" \
        "" \
        "history/*.shot:" \
        "file: [_display [_dget $legacy_info path]]" \
        "status: [_dget $legacy_info status] [_dget $legacy_info message]" \
        "bean_brand: [_display [_dget $legacy_values bean_brand]]" \
        "bean_type: [_display [_dget $legacy_values bean_type]]" \
        "grinder_setting: [_display [_dget $legacy_values grinder_setting]]" \
        "grinder_dose_weight: [_display [_dget $legacy_values grinder_dose_weight]]" \
        "drink_weight: [_display [_dget $legacy_values drink_weight]]" \
        "espresso_notes: [_display [_dget $legacy_values espresso_notes]]" \
        "my_name: [_display [_dget $legacy_values my_name]]" \
        "drinker_name: [_display [_dget $legacy_values drinker_name]]" \
        "" \
        "history_v2/*.json:" \
        "file: [_display [_dget $json_info path]]" \
        "status: [_dget $json_info status] [_dget $json_info message]" \
        "meta.bean: brand=[_display [_dget $json_values bean_brand]], type=[_display [_dget $json_values bean_type]], notes=[_display [_dget $json_values bean_notes]], roast=[_display [_dget $json_values roast_level]] [_display [_dget $json_values roast_date]]" \
        "meta.shot: notes=[_display [_dget $json_values espresso_notes]], enjoyment=[_display [_dget $json_values espresso_enjoyment]], tds=[_display [_dget $json_values drink_tds]], ey=[_display [_dget $json_values drink_ey]]" \
        "meta.grinder: model=[_display [_dget $json_values grinder_model]], setting=[_display [_dget $json_values grinder_setting]]" \
        "meta.in: [_display [_dget $json_values grinder_dose_weight]]" \
        "meta.out: [_display [_dget $json_values drink_weight]]" \
        "meta.time: [_display [_dget $json_values extraction_time]]" \
        ""]

    foreach line [_comparison_lines $display_row $legacy_values $json_values] {
        lappend lines $line
    }
    return [join $lines "\n"]
}

proc ::plugins::ShotHistoryEditor::_count_files {dir pattern} {
    if {![file isdirectory $dir]} { return 0 }
    return [llength [glob -nocomplain -directory $dir $pattern]]
}

proc ::plugins::ShotHistoryEditor::diagnostics_text {} {
    variable last_error
    variable table_used
    variable detected_objects

    set db [_open_ro_db]
    set shot_count "not available"
    set schema_issue ""
    if {$db ne ""} {
        set table [_choose_source $db]
        if {$table ne ""} {
            if {[catch { set shot_count [$db onecolumn "SELECT COUNT(*) FROM [_q $table]"] } err]} {
                set shot_count "not available"
                set schema_issue $err
            }
        } else {
            set schema_issue "No V_shot view or shot table detected."
        }
        _close_db
    } else {
        set schema_issue $last_error
    }

    set object_lines {}
    foreach item $detected_objects {
        lappend object_lines "[dict get $item type]: [dict get $item name]"
    }
    if {[llength $object_lines] == 0} { lappend object_lines "none detected" }

    set history_dir [history_path]
    set history_v2_dir [history_v2_path]
    set issues {}
    if {![file isfile [sdb_path]]} { lappend issues "SDB database file is missing." }
    if {![file isdirectory $history_dir]} { lappend issues "history folder is missing." }
    if {![file isdirectory $history_v2_dir]} { lappend issues "history_v2 folder is missing." }
    if {$schema_issue ne ""} { lappend issues "Schema issue: $schema_issue" }
    if {[llength $issues] == 0} { lappend issues "No missing folders or schema issues detected." }
    set selected_info [_selected_source_info]

    set deleted_n [deleted_shot_count]

    return [join [list \
        "SDB database path: [sdb_path]" \
        "Detected SDB tables/views:" \
        "  [join $object_lines "\n  "]" \
        "Detected table/view used: [_display $table_used]" \
        "Scrolling support: [scrolling_support_text]" \
        "Data root (history, history_v2): [_data_root] ([_pick [llength [info commands ::data_directory]] {the app's data_directory} {homedir: this app has no data_directory}])" \
        "history folder path: $history_dir" \
        "history_v2 folder path: $history_v2_dir" \
        "Number of SDB shots found: $shot_count" \
        "Number of .shot files found: [_count_files $history_dir *.shot]" \
        "Number of .json files found: [_count_files $history_v2_dir *.json]" \
        "Selected shot: [_display [_dget $selected_info filename]]" \
        "Matching .shot file exists: [_dget $selected_info shot_exists]" \
        "Matching history_v2 JSON exists: [_dget $selected_info json_exists]" \
        "Editable fields detected in selected .shot: [_dget $selected_info editable_count]" \
        "Trash folder path: [trash_dir]" \
        "Trash manifest path: [trash_manifest_path]" \
        "Delete log path: [delete_log_path]" \
        "$deleted_n deleted shot(s) hidden (SDB not modified; it may resync on its own)." \
        "Hidden shots that exist on disk again: [reconcile_count] (Advanced > Reconcile hidden shots)" \
        "Reconcile manifest path: [reconcile_manifest_path]" \
        "Backups folder path: [backups_dir]" \
        "Edit manifest path: [edit_manifest_path]" \
        "Edit log path: [edit_log_path]" \
        "SHE's own files: [_she_data_dir] (state: [dict get [_she_layout] state]; history_trash: [_she_new_root]; legacy: [join [_she_legacy_roots] {, }])" \
        "Bag fields in SDB (Bags view): [_bag_field_detect]" \
        "Issues:" \
        "  [join $issues "\n  "]"] "\n"]
}

# v0.19.1: the Help text as a list of pages, split at the "Raw pressure"
# paragraph (help_text keeps its one-string form).
proc ::plugins::ShotHistoryEditor::help_pages {} {
    set lines [split [help_text] "\n"]
    set cut [lsearch -glob $lines "Raw pressure*"]
    return [list [join [lrange $lines 0 [expr {$cut - 2}]] "\n"] \
                 [join [lrange $lines $cut end] "\n"]]
}

proc ::plugins::ShotHistoryEditor::help_text {} {
    return [join [list \
        "SDB is used for browsing and searching recent shots and is never written to." \
        "The legacy history/*.shot settings block is the durable, real source for editable metadata." \
        "history_v2 (v0.24.0): a Save also changes the edited fields in the shot's history_v2 .json (backup, check, rename); a failure there never undoes the .shot. A delete moves the .json with the .shot." \
        "Edit Preview shows those history_v2 values, old -> new, and whether the changed file checks out; a shot without a .json is left alone." \
        "" \
        "Real metadata save (v0.5.0): pick one safe field, type a value, Preview Change, then Save Change and confirm. Only that one settings line of history/<filename>.shot is rewritten, after a whole-file backup (in SHE's backups/ folder, history_trash/backups/ after the move) and verified before and after; a failed save is put back from the backup and checked. SDB is never written; history_v2 follows as above." \
        "" \
        "Safe editable fields:" \
        "grinder_setting, grinder_dose_weight, drink_weight, bean_brand, bean_type, espresso_notes, my_name, drinker_name." \
        "" \
        "Soft delete (v0.4.0): selecting shots and tapping Delete opens a two-step confirmation (Review, then a typed Confirm). Confirming MOVES history/<filename>.shot and, if present, history_v2/<filename>.json into SHE's trash/ folder (history_trash/trash/ after the move) -- files are only moved and never edited; only Empty trash deletes them, .json files included. SDB itself is never written to, so deleted shots are hidden by filtering the list against a manifest file, not by changing SDB." \
        "Advanced > Trash / Restore lists every deleted batch and can move its files back into history/ and history_v2/." \
        "Empty trash (Trash page) permanently removes every file in SHE's trash (each deleted shot's .shot and its history_v2 .json) after a typed confirmation; nothing else in history/ or history_v2/ is touched." \
        "Move trash and logs (Advanced, v0.22.0): moves the trash, backups and logs once from the plugin folder to history_trash/ in the app's data folder, by renaming only, after a typed count. A new install starts there." \
        "" \
        "Raw pressure, flow, temperature, resistance, shot_series, chart arrays, and machine sensor data are off-limits -- never displayed for editing, never modified." \
        "Reconcile hidden shots (Advanced, v0.10.0): shots the trash manifest still hides although their file is back in history/. Unhide appends one marker line to reconcile_manifest.txt (plus an audit line); the trash entry is never edited." \
        "" \
        "Bags (v0.16.0): the Bags tab groups shots by roaster and bag name, newest first. Edit bag changes a bag's roaster, name, notes, roast date or roast level in every file of the bag (cleaning runs included): Review shows each field now and after, then Save asks you to type the number of files. Each file is backed up to SHE's backups/ folder and checked first, rewritten (only those settings lines) and checked again; a failed check restores its backup. edit_log.txt records every file. SDB is never written; each saved file's history_v2 copy gets the same changed fields. If the bag is the one loaded for your next shot (DYE's plan), Save updates the next shot too; Review says so and the result page lists what changed (without DYE it lists what to enter again)." \
        "Cleaning runs are marked CLEANING on the Shots tab and never counted as shots." \
        "" \
        "Rinse, flush, steam, hot water, and cleaning shots never trigger anything in this plugin -- it has no automatic hooks at all."] "\n"]
}

proc ::plugins::ShotHistoryEditor::select_recent_row {idx} {
    variable recent_rows
    variable selected_row
    if {$idx < 0 || $idx >= [llength $recent_rows]} { return }
    set selected_row [lindex $recent_rows $idx]
    open_page ShotHistoryEditor_detail
}

proc ::plugins::ShotHistoryEditor::refresh_recent_page {page} {
    variable recent_rows
    variable last_error
    variable max_recent
    load_recent_shots

    if {[llength $recent_rows] == 0} {
        set status "No recent SDB shots found."
        if {$last_error ne ""} { append status "\n$last_error" }
    } else {
        set status "Showing latest [llength $recent_rows] SDB shots. Select Open for source detail."
    }
    catch { dui item config $page recent_status -text $status }

    for {set i 0} {$i < $max_recent} {incr i} {
        if {$i < [llength $recent_rows]} {
            set row [lindex $recent_rows $i]
            set bean [_bean_label [_dget $row bean_brand] [_dget $row bean_type]]
            set text "[_fmt_time [_dget $row clock]] | [_display [_dget $row filename]] | grind [_display [_dget $row grinder_setting]] | dose [_display [_dget $row grinder_dose_weight]] | yield [_display [_dget $row drink_weight]] | $bean | time [_display [_dget $row extraction_time]]"
            catch { dui item config $page row${i}_text -text $text }
            catch { dui item show $page row${i}_open* -initial 1 }
        } else {
            catch { dui item config $page row${i}_text -text "" }
            # v0.8.3: -initial 1, the same form the card list and Trash page
            # use since v0.8.1, so a hidden Open cannot flash back on the
            # framework's pre-show{} re-show.
            catch { dui item hide $page row${i}_open* -initial 1 }
        }
    }
}

# ---------------------------------------------------------------------------
# Pass 3/4.0 -- main-page card list, selection mode, and real soft delete.
# Card selection only drives an in-memory "sel" array (never SDB). SDB is
# never written to. Actual file moves only happen in perform_delete_batch/
# restore_batch, both further below, and only after the Review/Confirm flow.
# ---------------------------------------------------------------------------

proc ::plugins::ShotHistoryEditor::load_recent_shots_paged {offset limit} {
    variable card_rows
    variable last_error

    set card_rows {}
    set last_error ""
    set db [_open_ro_db]
    if {$db eq ""} { return $card_rows }

    set table [_choose_source $db]
    if {$table eq ""} {
        set last_error "No SDB shot table or V_shot view detected."
        _close_db
        return $card_rows
    }

    set cols [_columns $db $table]
    # v0.16.0: beverage_type marks cleaning runs (_is_cleaning_row).
    # v0.17.0: file_modification_date retires bag-save overlays (_apply_edit_overlay).
    set aliases {clock filename profile_title grinder_setting grinder_dose_weight drink_weight bean_brand bean_type espresso_notes extraction_time removed beverage_type file_modification_date}
    set select_parts {}
    foreach alias $aliases {
        lappend select_parts [_select_expr $cols $alias $alias]
    }

    set sql "SELECT [join $select_parts {, }] FROM [_q $table]"
    if {[_has_col $cols removed]} {
        append sql " WHERE (removed IS NULL OR removed=0)"
    }
    if {[_has_col $cols clock]} {
        append sql " ORDER BY [_q clock] DESC"
    } elseif {[_has_col $cols filename]} {
        append sql " ORDER BY [_q filename] DESC"
    }
    # Soft-deleted shots are invisible to SDB (never modified), so this
    # scans from the top and filters/slices in Tcl instead of using SQL
    # OFFSET directly -- otherwise a deleted row between two pages would
    # shift every later page by one and could under-fill a page.
    set scan_cap [expr {$offset + $limit + 200}]
    append sql " LIMIT $scan_cap"

    set deleted [_deleted_filenames_dict]
    set overlays [_all_edit_overlays]
    set matched {}
    if {[catch {
        $db eval $sql row {
            if {[dict exists $deleted $row(filename)]} { continue }
            set item {}
            foreach a $aliases {
                dict set item $a $row($a)
            }
            dict set item table_used $table
            set item [_apply_edit_overlay $item $overlays]
            lappend matched $item
            if {[llength $matched] >= $offset + $limit} { break }
        }
    } err]} {
        set last_error "Could not read recent shots: $err"
    }
    set card_rows [lrange $matched $offset [expr {$offset + $limit - 1}]]

    _close_db
    return $card_rows
}

proc ::plugins::ShotHistoryEditor::_total_shot_count {} {
    set n ""
    set db [_open_ro_db]
    if {$db eq ""} { return $n }
    set table [_choose_source $db]
    if {$table ne ""} {
        set where ""
        if {[_has_col [_columns $db $table] removed]} { set where " WHERE (removed IS NULL OR removed=0)" }
        catch { set n [$db onecolumn "SELECT COUNT(*) FROM [_q $table]$where"] }
    }
    _close_db
    return $n
}

# Count of shots the card pager can actually reach: the SAME removed-column
# filter and the SAME trash-manifest filename filter as
# load_recent_shots_paged, so "Showing x-y of N" and the last page always
# agree. v0.8.1 bugfix: the old version subtracted the WHOLE trash manifest
# from SDB's raw count, but SDB's own resync also flags trashed files
# removed=1 -- those shots were then subtracted twice, under-reporting the
# total (tablet showed "Showing 121-121 of 106 shots") while Next kept
# finding real rows past the fake total.
proc ::plugins::ShotHistoryEditor::_visible_shot_count {} {
    set n ""
    set db [_open_ro_db]
    if {$db eq ""} { return $n }
    set table [_choose_source $db]
    if {$table ne ""} {
        set cols [_columns $db $table]
        set where ""
        if {[_has_col $cols removed]} { set where " WHERE (removed IS NULL OR removed=0)" }
        if {[_has_col $cols filename]} {
            set deleted [_deleted_filenames_dict]
            set count 0
            if {![catch {
                $db eval "SELECT [_q filename] AS fn FROM [_q $table]$where" row {
                    if {![dict exists $deleted $row(fn)]} { incr count }
                }
            }]} {
                set n $count
            }
        } else {
            # No filename column detected: the pager cannot filter by the
            # trash manifest either, so the raw count IS the reachable count.
            catch { set n [$db onecolumn "SELECT COUNT(*) FROM [_q $table]$where"] }
        }
    }
    _close_db
    return $n
}

# Looks up date/time (clock) and profile for a known list of filenames, used
# to build the Delete Review page. Filenames are always sourced internally
# (from card_rows/sel), never typed by a user, but _qval still escapes them.
proc ::plugins::ShotHistoryEditor::_lookup_shots_by_filename {filenames} {
    set rows {}
    if {[llength $filenames] == 0} { return $rows }
    set db [_open_ro_db]
    if {$db eq ""} { return $rows }
    set table [_choose_source $db]
    if {$table eq ""} { _close_db; return $rows }

    set cols [_columns $db $table]
    set aliases {clock filename profile_title}
    set select_parts {}
    foreach alias $aliases { lappend select_parts [_select_expr $cols $alias $alias] }
    set in_list [join [lmap fn $filenames { _qval $fn }] ", "]
    set sql "SELECT [join $select_parts {, }] FROM [_q $table] WHERE [_q filename] IN ($in_list)"

    catch {
        $db eval $sql row {
            set item {}
            foreach a $aliases { dict set item $a $row($a) }
            lappend rows $item
        }
    }
    _close_db
    return $rows
}

proc ::plugins::ShotHistoryEditor::selected_count {} {
    variable sel
    return [array size sel]
}

proc ::plugins::ShotHistoryEditor::_is_selected {filename} {
    variable sel
    return [info exists sel($filename)]
}

proc ::plugins::ShotHistoryEditor::clear_selection_state {} {
    variable sel
    array unset sel
}

# v0.15.0 (F12): Clear Selection repaints the cards and the bar only --
# selection never reads the database (paging and mode switches do).
proc ::plugins::ShotHistoryEditor::clear_selection {} {
    clear_selection_state
    _paint_all_card_sel ShotHistoryEditor_settings
    _refresh_select_bar ShotHistoryEditor_settings
}

# v0.15.0 (F12): one card's look follows its selection -- tint + value-blue
# outline when selected in Select mode, the plain card otherwise -- and its
# button label says Selected / Select (Edit outside Select mode).
proc ::plugins::ShotHistoryEditor::_paint_card_sel {page i} {
    variable L
    variable card_rows
    variable select_mode
    if {$i < 0 || $i >= [llength $card_rows]} { return }
    set filename [_dget [lindex $card_rows $i] filename]
    set on [expr {$select_mode && [_is_selected $filename]}]
    # v0.16.0: a cleaning run's card is tinted unless it is selected.
    set clean [_is_cleaning_row [lindex $card_rows $i]]
    catch { dui item config $page row${i}_bg \
        -fill [expr {$on ? $L(card_sel_bg) : ($clean ? $L(clean_bg) : $L(card_bg))}] \
        -outline [expr {$on ? $L(card_sel_outline) : ($clean ? $L(clean_outline) : $L(card_outline))}] }
    if {$select_mode} {
        set lbl [expr {$on ? "[_u 0x2611] Selected" : "[_u 0x2610] Select"}]
    } else {
        set lbl "[_u 0x270e] Edit"
    }
    catch { dui item config $page row${i}_btn -label [translate $lbl] }
}

proc ::plugins::ShotHistoryEditor::_paint_all_card_sel {page} {
    variable card_rows
    for {set i 0} {$i < [llength $card_rows]} {incr i} { _paint_card_sel $page $i }
}

# v0.15.0 (F12): the bottom-left slot (one dbutton, one dispatcher) reads
# "Delete N" on the danger face in Select mode, disabled while nothing is
# selected (it used to say "Delete" in Done's style and silently do
# nothing at 0), and "Done" in the normal style otherwise. The state goes
# through dui's enable_or_disable, which leaves a hidden page alone.
proc ::plugins::ShotHistoryEditor::_refresh_select_bar {page} {
    variable L
    variable select_mode
    set n [selected_count]
    if {$select_mode} {
        # The word is translated, the count appended (review: a "Delete 3"
        # key would be a new, never-translated string for every count).
        set lbl [translate "Delete"]
        if {$n > 0} { append lbl " $n" }
        set fill $L(btn_danger_fill) ; set ink $L(btn_danger_label)
        catch { dui item config $page recent_status \
            -text "$n selected. Tap cards to choose the shots to delete." }
    } else {
        set lbl [translate "Done"]
        set fill $L(btn_fill) ; set ink $L(btn_label_fill)
    }
    catch { dui item config $page bar_left -label $lbl }
    catch { dui item config $page bar_left-btn -fill $fill -outline $fill \
        -disabledfill $L(btn_disabled_fill) -disabledoutline $L(btn_disabled_fill) }
    catch { dui item config $page bar_left-lbl -fill $ink }
    catch { dui item enable_or_disable [expr {!$select_mode || $n > 0}] $page bar_left* }
    # v0.16.0: the Bags tab waits until Select mode ends.
    _refresh_view_tabs $page
}

proc ::plugins::ShotHistoryEditor::toggle_select_mode {} {
    variable select_mode
    if {$select_mode} {
        set select_mode 0
        clear_selection_state
    } else {
        set select_mode 1
    }
    refresh_main_page ShotHistoryEditor_settings
}

proc ::plugins::ShotHistoryEditor::row_toggle_select {i} {
    variable card_rows
    variable sel
    if {$i < 0 || $i >= [llength $card_rows]} { return }
    set filename [_dget [lindex $card_rows $i] filename]
    if {$filename eq ""} { return }
    if {[info exists sel($filename)]} {
        array unset sel $filename
    } else {
        set sel($filename) 1
    }
    # v0.15.0 (F12): repaint only this card and the bar -- no database read
    # per tap (refresh_main_page re-counted the whole shot table).
    _paint_card_sel ShotHistoryEditor_settings $i
    _refresh_select_bar ShotHistoryEditor_settings
}

# v0.15.0 (F12): a tap on a card's text area -- toggles it in Select mode,
# does nothing otherwise (the card button keeps Edit).
proc ::plugins::ShotHistoryEditor::card_tap_click {i} {
    variable select_mode
    if {$select_mode} { row_toggle_select $i }
}

proc ::plugins::ShotHistoryEditor::edit_from_card {i} {
    variable card_rows
    variable selected_row
    if {$i < 0 || $i >= [llength $card_rows]} { return }
    set selected_row [lindex $card_rows $i]
    open_edit_preview ShotHistoryEditor_settings
}

# Pass 3.1 -- single dispatcher per card button. There is exactly one dbutton
# per card row (no overlapping duplicate buttons, see the Part A fix note at
# the top of the settings page setup{}); this proc decides what a tap on that
# one button does, based on the current mode, instead of swapping widgets.
proc ::plugins::ShotHistoryEditor::card_btn_click {i} {
    variable select_mode
    if {$select_mode} {
        row_toggle_select $i
    } else {
        edit_from_card $i
    }
}

# Single dispatcher for the bottom-left bar button (Done in normal mode,
# Delete in selection mode).
#
# v0.5.2: Done no longer calls dui page close_dialog directly -- see
# _navigate_done's note above. Uses the return page captured by the
# Settings page's own show{} instead of trusting close_dialog's "previous".
proc ::plugins::ShotHistoryEditor::bar_left_click {} {
    variable select_mode
    variable _settings_return_page
    if {$select_mode} {
        if {[selected_count] > 0} { open_delete_review }
    } else {
        _navigate_done $_settings_return_page
    }
}

# Single dispatcher for the bottom-right bar button (Advanced in normal mode,
# Clear Selection in selection mode).
proc ::plugins::ShotHistoryEditor::bar_right_click {} {
    variable select_mode
    if {$select_mode} {
        clear_selection
    } else {
        open_page ShotHistoryEditor_advanced
    }
}

proc ::plugins::ShotHistoryEditor::scroll_cards {delta} {
    variable card_offset
    variable card_page_size
    incr card_offset [expr {$delta * $card_page_size}]
    if {$card_offset < 0} { set card_offset 0 }
    refresh_main_page ShotHistoryEditor_settings
}

# ---------------------------------------------------------------------------
# Pass 4.0 -- real soft-delete confirmation flow: Review -> Confirm -> Result.
# Cancel at either step (and the settings page's own defensive `show` reset)
# is what actually exits the flow -- no separate guard flag to get stuck.
# ---------------------------------------------------------------------------

# Step 1 entry point (from the main page's Delete button). Snapshots the
# selected filenames now, since selection could change if the user paged
# around before this point -- the Review/Confirm flow must describe exactly
# what will be deleted, not whatever is selected later.
proc ::plugins::ShotHistoryEditor::open_delete_review {} {
    variable sel
    variable review_filenames
    variable review_rows
    variable delete_result_text

    set review_filenames [lsort [array names sel]]
    set review_rows [_lookup_shots_by_filename $review_filenames]
    set delete_result_text ""
    set ::plugins::ShotHistoryEditor::delete_review_page_index 0
    open_page ShotHistoryEditor_delete_review
}

proc ::plugins::ShotHistoryEditor::_review_file_list_text {filename} {
    set legacy [_legacy_file $filename]
    set json [_json_file $filename]
    set has_shot [file isfile $legacy]
    set has_json [file isfile $json]
    if {$has_shot && $has_json} {
        return "history/$filename.shot, history_v2/$filename.json"
    } elseif {$has_shot} {
        return "history/$filename.shot only"
    } elseif {$has_json} {
        return "history_v2/$filename.json only"
    }
    return "no matching files found (already moved or missing)"
}

proc ::plugins::ShotHistoryEditor::build_delete_review_text {} {
    variable review_filenames
    variable review_rows

    if {[llength $review_filenames] == 0} {
        return "No shots selected."
    }

    array set by_filename {}
    foreach row $review_rows {
        set by_filename([_dget $row filename]) $row
    }

    set lines {}
    foreach fn $review_filenames {
        if {[info exists by_filename($fn)]} {
            set row $by_filename($fn)
            set label "[_fmt_time [_dget $row clock]]  |  $fn"
        } else {
            set label $fn
        }
        lappend lines $label
        lappend lines "  Files: [_review_file_list_text $fn]"
    }
    return [join $lines "\n"]
}

proc ::plugins::ShotHistoryEditor::cancel_delete_review {} {
    _return_to_page ShotHistoryEditor_settings
}

proc ::plugins::ShotHistoryEditor::refresh_delete_review_page {page} {
    variable review_filenames
    set n [llength $review_filenames]
    catch { dui item config $page review_count_text -text "$n shot(s) selected" }
    set ::plugins::ShotHistoryEditor::delete_review_page_index 0
    scroll_page delete_review 0 $page
}

# Step 2 entry point.
proc ::plugins::ShotHistoryEditor::open_delete_confirm {} {
    variable confirm_input
    variable confirm_error
    set confirm_input ""
    set confirm_error ""
    open_page ShotHistoryEditor_delete_confirm
}

proc ::plugins::ShotHistoryEditor::cancel_delete_confirm {} {
    _return_to_page ShotHistoryEditor_settings
}

proc ::plugins::ShotHistoryEditor::refresh_delete_confirm_page {page} {
    variable review_filenames
    variable confirm_error
    set n [llength $review_filenames]
    catch { dui item config $page confirm_instructions -text \
        "Type $n (the number of shots being deleted) below, then tap Confirm Delete." }
    catch { dui item config $page confirm_error_text -text $confirm_error }
}

# Typed strong-confirmation submit. Chosen over hold-to-confirm because this
# codebase has no existing press-and-hold/progress-timer UI pattern to build
# on (nothing in plugins/SDB, plugins/GrindAdvisor, or plugins/visualizer_upload
# implements one), and the spec explicitly allows a typed count as the
# fallback when hold-to-confirm isn't reliably implementable -- for the
# first destructive-capability pass, a proven, unambiguous confirmation is
# safer than a novel interaction with no precedent to verify against.
proc ::plugins::ShotHistoryEditor::confirm_delete_submit {} {
    variable review_filenames
    variable confirm_input
    variable confirm_error
    variable delete_result_text

    set n [llength $review_filenames]
    set typed [string trim $confirm_input]
    if {$typed ne [expr {$n}]} {
        set confirm_error "Type exactly \"$n\" to confirm. Nothing was deleted."
        refresh_delete_confirm_page ShotHistoryEditor_delete_confirm
        return
    }

    set result [perform_delete_batch $review_filenames]
    set moved_files [dict get $result moved_files]
    set shot_count [dict get $result shot_count]
    set failed [dict get $result failed]
    set trash_path [dict get $result trash_path]

    set lines [list]
    # v0.23.1: the trash manifest could not take the batch's lines, so the
    # files went back (or some could not): no undo through Trash / Restore.
    if {[dict exists $result put_back]} {
        lappend lines "Not deleted: [dict get $result message]"
        set stuck [dict get $result stuck]
        if {[llength $stuck]} {
            lappend lines ""
            lappend lines "These [llength $stuck] file(s) are in $trash_path but NOT in the trash list, so Trash / Restore cannot see them:"
            foreach s $stuck { lappend lines "  $s" }
            lappend lines "Move them back into history/ (or history_v2/ for a .json) by hand; see the app log."
        }
        set delete_result_text [join $lines "\n"]
        open_page ShotHistoryEditor_delete_result
        return
    }
    if {[dict get $result ok]} {
        lappend lines "Moved $moved_files file(s) for $shot_count shot(s) to SHE's trash folder."
    } else {
        lappend lines "Stopped: [dict get $result message]"
        lappend lines "Moved $moved_files file(s) for $shot_count shot(s) before stopping."
    }
    lappend lines "Trash location: $trash_path"
    if {[llength $failed] > 0} {
        lappend lines ""
        lappend lines "Not moved:"
        foreach f $failed {
            lappend lines "  [dict get $f filename]: [dict get $f reason]"
        }
    }
    lappend lines ""
    # v0.6.3: say whether the recommendation was recomputed, the same way the
    # edit result page does. Before this the deleted shots kept counting
    # towards the grind recommendation and nothing on screen said so.
    set note [_dget $result refresh_note ""]
    if {$note ne ""} {
        lappend lines "Grind Advisor: $note"
    } else {
        lappend lines "SDB is not written to directly; the card list overlays this until SDB resyncs."
    }
    if {[dict get $result moved_files] > 0 && ![_dget $result log_ok 1]} {
        lappend lines "WARNING: delete_log.txt could not be written (the trash manifest was); see the app log."
    }
    lappend lines ""
    lappend lines "Nothing was permanently deleted. Use Advanced > Trash / Restore to undo."
    set delete_result_text [join $lines "\n"]

    open_page ShotHistoryEditor_delete_result
}

proc ::plugins::ShotHistoryEditor::refresh_delete_result_page {page} {
    variable delete_result_text
    catch { dui item config $page result_text -text $delete_result_text }
}

# Exit point: returns to the main page, which (via its own `show` proc)
# unconditionally resets select_mode/sel and reloads the card list, so
# deleted shots disappear immediately -- no separate "refresh" call needed.
# v0.4.1 bugfix: this used to call open_page, which tries `dui page
# open_dialog` on ShotHistoryEditor_settings -- a page already open 3 levels
# down the stack (settings -> review -> confirm -> result). That call did
# not throw (so open_page's catch treated it as success and never tried
# `load`/`show`), but it also performed no real page transition, so Done
# appeared to do nothing: no error, no crash, no navigation. See
# _return_to_page for the proven fix (GrindAdvisor.tcl:412-439).
proc ::plugins::ShotHistoryEditor::close_delete_result {} {
    _return_to_page ShotHistoryEditor_settings
}

# ---------------------------------------------------------------------------
# Pass 4.0 -- Trash / Restore page (under Advanced).
# ---------------------------------------------------------------------------

proc ::plugins::ShotHistoryEditor::restore_trash_batch {batch_id} {
    variable trash_offset
    variable tidy_note
    set result [restore_batch $batch_id]
    set trash_offset 0
    # v0.20.0: the page's one-shot note (Tidy's since v0.15.2) also carries a
    # restore that kept or refused files or could not update the trash list.
    set tidy_note [_dget $result trash_note]
    refresh_trash_page ShotHistoryEditor_trash
    return $result
}

proc ::plugins::ShotHistoryEditor::scroll_trash {delta} {
    variable trash_offset
    variable trash_page_size
    incr trash_offset [expr {$delta * $trash_page_size}]
    if {$trash_offset < 0} { set trash_offset 0 }
    refresh_trash_page ShotHistoryEditor_trash
}

proc ::plugins::ShotHistoryEditor::refresh_trash_page {page} {
    variable trash_offset
    variable trash_page_size
    variable tidy_note

    set batches [_trash_batches]
    set total [llength $batches]
    # v0.9.1: clamp the offset to the last real page (same rule as the card
    # list since v0.8.1), so Next can never walk past the end and a restore
    # that empties the last page snaps back instead of showing nothing.
    if {$total <= 0} {
        set trash_offset 0
    } else {
        set max_offset [expr {(($total - 1) / $trash_page_size) * $trash_page_size}]
        if {$trash_offset > $max_offset} { set trash_offset $max_offset }
    }
    if {$trash_offset < 0} { set trash_offset 0 }
    set shown [lrange $batches $trash_offset [expr {$trash_offset + $trash_page_size - 1}]]

    if {$total == 0} {
        set status "No trashed shots. Deleted shots appear here as restorable batches."
    } else {
        set from [expr {$trash_offset + 1}]
        set to [expr {$trash_offset + [llength $shown]}]
        set status "Showing $from-$to of $total batch(es)."
    }
    # v0.15.2 (F18): the Tidy result, on the page that holds the button.
    if {$tidy_note ne ""} { append status "\n" $tidy_note }
    catch { dui item config $page trash_status -text $status }

    # v0.14.0 (F6): one card per batch, shown and hidden exactly as the main
    # page's cards are (every part with -initial 1, the button by its
    # literal <tag>* group tag).
    for {set i 0} {$i < $trash_page_size} {incr i} {
        if {$i < [llength $shown]} {
            lassign [_trash_card_lines [lindex $shown $i]] line1 line2 line3
            catch { dui item show $page row${i}_bg -initial 1 }
            catch { dui item config $page row${i}_line1 -text $line1 }
            catch { dui item config $page row${i}_line2 -text $line2 }
            catch { dui item config $page row${i}_line3 -text $line3 }
            catch { dui item show $page row${i}_line1 -initial 1 }
            catch { dui item show $page row${i}_line2 -initial 1 }
            catch { dui item show $page row${i}_line3 -initial 1 }
            catch { dui item show $page row${i}_restore* -initial 1 }
        } else {
            catch { dui item hide $page row${i}_bg -initial 1 }
            catch { dui item config $page row${i}_line1 -text "" }
            catch { dui item config $page row${i}_line2 -text "" }
            catch { dui item config $page row${i}_line3 -text "" }
            catch { dui item hide $page row${i}_line1 -initial 1 }
            catch { dui item hide $page row${i}_line2 -initial 1 }
            catch { dui item hide $page row${i}_line3 -initial 1 }
            catch { dui item hide $page row${i}_restore* -initial 1 }
        }
    }

    # v0.8.1: wildcard tag form for dbutton show/hide -- see the note in
    # refresh_main_page. The old bare-tag hides left dead-but-visible
    # Restore/Prev buttons on this page too.
    # v0.9.1: Next exists (older batches were unreachable without it).
    # v0.13.1: both pager buttons stay visible; the unavailable one (first
    # page / last page / empty list) is disabled instead of hidden.
    _set_pager_state $page trash_prev_page trash_next_page \
        [expr {$trash_offset > 0}] [expr {$trash_offset + [llength $shown] < $total}]
    # v0.15.2 (F18): the Tidy count, LAST (review): cards and pager are
    # already right if the trash folder ever misbehaves.
    _refresh_tidy_btn $page
}

proc ::plugins::ShotHistoryEditor::restore_row {i} {
    variable trash_offset
    variable trash_page_size
    set batches [_trash_batches]
    set shown [lrange $batches $trash_offset [expr {$trash_offset + $trash_page_size - 1}]]
    if {$i < 0 || $i >= [llength $shown]} { return }
    set batch_id [dict get [lindex $shown $i] batch_id]
    restore_trash_batch $batch_id
}

proc ::plugins::ShotHistoryEditor::refresh_main_page {page} {
    variable card_rows
    variable card_offset
    variable card_page_size
    variable last_error
    variable select_mode

    # v0.8.1: clamp the offset to the last real page BEFORE loading, using
    # the same-filtered count (see _visible_shot_count), so Next can never
    # walk past the end and a delete that shrinks the list snaps the view
    # back to the last page instead of stranding it on an empty one.
    set total [_visible_shot_count]
    if {$total ne ""} {
        if {$total <= 0} {
            set card_offset 0
        } else {
            set max_offset [expr {(($total - 1) / $card_page_size) * $card_page_size}]
            if {$card_offset > $max_offset} { set card_offset $max_offset }
        }
    }
    if {$card_offset < 0} { set card_offset 0 }

    load_recent_shots_paged $card_offset $card_page_size
    set shown [llength $card_rows]

    # Toolbar status / paging label.
    if {$select_mode} {
        set status "[selected_count] selected. Tap cards to choose the shots to delete."
    } elseif {$shown == 0} {
        set status "No recent SDB shots found."
        if {$last_error ne ""} { append status "\n$last_error" }
    } else {
        set from [expr {$card_offset + 1}]
        set to [expr {$card_offset + $shown}]
        if {$total ne ""} {
            set status "Showing $from-$to of $total shots, newest first."
        } else {
            set status "Showing $from-$to, newest first."
        }
    }
    catch { dui item config $page recent_status -text $status }

    # Mode button (top-right) and bottom bar: one physical button per slot,
    # command never changes -- only the caption is reconfigured. See the Part
    # A fix note in the settings page setup{} for why this replaced the
    # overlapping-duplicate-button design from v0.3.0.
    catch { dui item config $page mode_btn -label [translate [expr {$select_mode ? "Cancel" : "Select"}]] }
    catch { dui item config $page bar_right -label [translate [expr {$select_mode ? "Clear Selection" : "Advanced"}]] }
    # v0.15.0 (F12): "Delete N" on the danger face / "Done" (see the proc).
    _refresh_select_bar $page

    for {set i 0} {$i < $card_page_size} {incr i} {
        if {$i < $shown} {
            set row [lindex $card_rows $i]
            set filename [_dget $row filename]
            set bean [_bean_label [_dget $row bean_brand] [_dget $row bean_type]]
            set profile [_display [_dget $row profile_title]]
            set line1 "[_fmt_time [_dget $row clock]]   |   $filename"
            set line2 "Grind [_display [_dget $row grinder_setting]]   Dose [_display [_dget $row grinder_dose_weight]]g   Yield [_display [_dget $row drink_weight]]g   |   [_display [_dget $row extraction_time]]s"
            set line3 "Bean: $bean   |   Profile: $profile"
            # v0.16.0: a cleaning run says so -- tinted card (_paint_card_sel)
            # and a CLEANING pill at the right end of line 1.
            set clean [_is_cleaning_row $row]
            if {$clean} {
                set line2 "Cleaning run   |   not counted as a shot   |   [_display [_dget $row extraction_time]]s"
            }
            _vis $page [list row${i}_clean_bg row${i}_clean_txt] $clean

            catch { dui item show $page row${i}_bg -initial 1 }
            catch { dui item config $page row${i}_line1 -text $line1 }
            catch { dui item config $page row${i}_line2 -text $line2 }
            catch { dui item config $page row${i}_line3 -text $line3 }
            catch { dui item show $page row${i}_line1 -initial 1 }
            catch { dui item show $page row${i}_line2 -initial 1 }
            catch { dui item show $page row${i}_line3 -initial 1 }
            catch { dui item show $page row${i}_btn* -initial 1 }
            catch { dui item show $page she_row${i}_tap* -initial 1 }

            # v0.15.0 (F12): tint/outline and button label by selection.
            _paint_card_sel $page $i
        } else {
            catch { dui item hide $page row${i}_bg -initial 1 }
            catch { dui item config $page row${i}_line1 -text "" }
            catch { dui item config $page row${i}_line2 -text "" }
            catch { dui item config $page row${i}_line3 -text "" }
            catch { dui item hide $page row${i}_line1 -initial 1 }
            catch { dui item hide $page row${i}_line2 -initial 1 }
            catch { dui item hide $page row${i}_line3 -initial 1 }
            catch { dui item hide $page row${i}_btn* -initial 1 }
            catch { dui item hide $page she_row${i}_tap* -initial 1 }
            _vis $page [list row${i}_clean_bg row${i}_clean_txt] 0
        }
    }

    # v0.8.1: dbutton show/hide MUST use the wildcard tag form. dui gives a
    # dbutton's visible shape/label their own -btn/-lbl tags plus a shared
    # literal "<tag>*" tag (de1app-core/dui.tcl process_tags_and_var); the
    # bare tag only matches the invisible clickable rect, so the old bare-tag
    # hides left Prev and the empty rows' Edit buttons fully visible (but
    # dead) on the tablet. Same form every reference plugin uses (A_Flow,
    # DPx_Flow_Calibrator: "dui item hide <page> <tag>*"). -initial 1 also
    # persists the state through the framework's pre-show{} re-show of all
    # items, so hidden buttons cannot flash back on a page revisit.
    # v0.13.1: the pager no longer hides -- both buttons stay put and the
    # unavailable one is disabled (_set_pager_state). Next is unavailable
    # on the last page (offset+shown reaches the clamped total); when the
    # total is unknown (SDB unreadable), "a full page probably has a next
    # one".
    _set_pager_state $page prev_page next_page [expr {$card_offset > 0}] \
        [expr {($total ne "" && $card_offset + $shown < $total) ||
               ($total eq "" && $shown == $card_page_size)}]
}

# ---------------------------------------------------------------------------
# v0.16.0 -- Bags view (pass A, READ-ONLY). Shots are grouped into bags by
# roaster (bean_brand) and bag name (bean_type), read from SDB through the
# same read-only handle, removed-column filter, trash-manifest filter and
# edit overlay as the card list. The Edit bag page and its Review page are a
# PREVIEW: Save is disabled and nothing in this section writes, moves,
# renames or deletes a file. Cleaning runs carry the bag that was loaded
# when they ran, so they belong to that bag (owner 2026-10-01: a bag edit
# includes them) but are never counted as shots.
# ---------------------------------------------------------------------------

namespace eval ::plugins::ShotHistoryEditor {
    variable bag_page_size 6
    variable bag_offset 0
    # Every bag of the last Bags read (dicts, newest first); the pages paint
    # from this cache, so a theme switch never reads the database.
    variable bag_list {}
    # The bag the editor is showing (a snapshot of one bag_list entry).
    variable bag_cur {}
    variable bag_edit_roaster ""
    variable bag_edit_name ""
    variable bag_edit_notes ""
    variable bag_edit_date ""
    variable bag_edit_level ""
    variable bag_notes_widget ""
    # Roast-level choices on the Edit bag page; the empty one is "None".
    variable bag_levels {"" Light Medium-Light Medium Medium-Dark Dark}
    # The bag fields, in display order: settings key, label.
    variable bag_fields {bean_brand Roaster bean_type {Bag name} bean_notes Notes roast_date {Roast date} roast_level {Roast level}}
    # Card-face tile parts (plain canvas items) of one Bags tile.
    variable bag_tile_parts {bg roaster pill_bg pill_txt name lvl_bg lvl_dot lvl_txt date_bg date_txt notes count span clean}
}

# Bags view and cleaning-run colours, called at the end of _apply_palette.
# Pairs (WCAG 2.1, checked by the pass 0.16.0 offline test): card texts on
# clean_bg, clean_pill_text on clean_pill_bg, clean_text on card_bg,
# inuse_text on inuse_bg, choice_on_label on choice_on_fill.
proc ::plugins::ShotHistoryEditor::_apply_bag_palette {dark} {
    variable L
    if {$dark} {
        set L(clean_bg)        "#21333a"
        set L(clean_outline)   "#3c6460"
        set L(clean_pill_bg)   "#2f5a55"
        set L(clean_pill_text) "#c4f5ec"
        set L(clean_text)      "#8fdccf"
        set L(chip_bg)         "#41475a"
        set L(chip_missing)    "#6a7186"
        set L(choice_on_fill)  "#8ab4ff"
        set L(choice_on_label) "#16213a"
        set L(inuse_bg)        "#2c3b5e"
        set L(inuse_text)      "#b9d0ff"
    } else {
        set L(clean_bg)        "#e3f4f1"
        set L(clean_outline)   "#8cc9bf"
        set L(clean_pill_bg)   "#1f6b62"
        set L(clean_pill_text) "#ffffff"
        set L(clean_text)      "#1d6158"
        set L(chip_bg)         "#e6e8f2"
        set L(chip_missing)    "#8a8fa3"
        set L(choice_on_fill)  "#2753bb"
        set L(choice_on_label) "#ffffff"
        set L(inuse_bg)        "#dde6ff"
        set L(inuse_text)      "#1f3f99"
    }
    set L(dot_outline) "#8a8f9c"
    set L(dot_unknown) "#9aa0ad"
}

# Bags view layout tokens, called at the end of _init_layout: reference px
# at 1340x800, scaled like every other token. No coordinate below this
# block is a bare number.
proc ::plugins::ShotHistoryEditor::_init_bag_layout {} {
    variable L
    set s $L(scale)
    foreach {tok ref} {
        top_btn_y 11 tab_w 130 clean_pill_w 120 clean_pill_h 24
        bag_roaster_dy 13 bag_pill_dy 11 bag_pill_w 85 bag_pill_h 24 bag_name_dy 35
        bag_chip_dy 70 bag_chip_h 28 bag_lvl_chip_w 180 bag_date_chip_w 150
        bag_dot_r 6 bag_dot_dx 18 bag_notes_dy 108 bag_footer_dy 160 bag_btn_w 130
        be_col_gap 28 be_label_h 26 be_entry_h 48 be_notes_h 80 be_date_w 300
        be_rowA_y 100 be_rowB_y 186 be_rowC_y 304 be_rowD_y 406 be_panel_y0 504
        be_div_w 1 rv_head_y 104 rv_row_y0 132 rv_row_h 40 rv_x_now 240 rv_x_after 660
        rv_warn_y 340 rv_panel_y0 396
    } {
        set L($tok) [expr {int(round($ref * $s))}]
    }
    set L(bag_cols) 3
    set L(bag_rows) 2
    set L(bag_tile_w) [expr {($L(content_w) - ($L(bag_cols) - 1) * $L(md)) / $L(bag_cols)}]
    set L(bag_tile_h) [expr {($L(bar_y0) - $L(md) - $L(list_top) - ($L(bag_rows) - 1) * $L(md)) / $L(bag_rows)}]
    set L(be_panel_y1) [expr {$L(bar_y0) - $L(md)}]
    set L(rv_panel_y1) [expr {$L(bar_y0) - $L(md)}]
    # Line heights in VIRTUAL units, from the real fonts (physical px, mapped
    # by sh/psh like caption_h in _init_layout); 1.36 em when there is no
    # font system. Stacked text below is spaced by these, never by guesses.
    foreach {tok ref} {body 19 section 24} {
        set L(${tok}_h) [expr {int(ceil($ref * 1.36 * $s))}]
        if {[llength [info commands font]] && [lsearch -exact [font names] $L(font_$tok)] >= 0} {
            set lh [font metrics $L(font_$tok) -linespace]
            if {$lh > 0} { set L(${tok}_h) [expr {int(ceil($lh * double($L(screen_h)) / $L(physical_screen_h)))}] }
        }
    }
    # Review page panels: title, body, and a two-line note at the bottom;
    # the Files list shows as many lines as fit between body and note.
    set L(rv_body_y) [expr {$L(rv_panel_y0) + $L(card_pad_y) + $L(section_h) + $L(md)}]
    set L(rv_note_y) [expr {$L(rv_panel_y1) - $L(card_pad_y) - 2 * $L(caption_h)}]
    set L(rv_fl_lines) [expr {max(1, min(7, ($L(rv_note_y) - $L(md) - $L(rv_body_y)) / $L(body_h)))}]
    # v0.17.0 Confirm page, top down: the change summary, up to five warning
    # lines (every warning Save can carry, one line each), the instruction, the typed entry (with Hide keyboard beside it)
    # and its error line all above y 800 (the Android keyboard), then the
    # what-happens panel down to the bar.
    set L(bc_changes_y) $L(toolbar_y0)
    set L(bc_warn_y) [expr {$L(bc_changes_y) + $L(caption_h) + $L(sm)}]
    set L(bc_warn_lines) 5
    set L(bc_instr_y) [expr {$L(bc_warn_y) + $L(bc_warn_lines) * $L(caption_h) + $L(sm)}]
    set L(bc_entry_y) [expr {$L(bc_instr_y) + $L(body_h) + $L(xs)}]
    set L(bc_error_y) [expr {$L(bc_entry_y) + $L(be_entry_h) + $L(sm)}]
    set L(bc_panel_y0) [expr {$L(bc_error_y) + $L(caption_h) + $L(md)}]
}

# A cleaning run: the app saves it as an ordinary shot with beverage_type
# "cleaning"; older runs are recognised by their profile title (the same
# words Grind Advisor rejects).
proc ::plugins::ShotHistoryEditor::_is_cleaning_row {row} {
    if {[string tolower [string trim [_dget $row beverage_type]]] eq "cleaning"} { return 1 }
    return [regexp -nocase {\m(clean|cleaning|descale|backflush)\M} [_dget $row profile_title]]
}

proc ::plugins::ShotHistoryEditor::_page_is_current {page} {
    set cur ""
    catch { set cur [dui page current] }
    return [expr {$cur eq $page}]
}

# Physical px of a virtual (2560-wide) horizontal distance -- dui's own
# conversion when the app runs. Text is measured in physical px by `font
# measure`, so both sides of every fit test are physical.
proc ::plugins::ShotHistoryEditor::_phys_w {v} {
    variable L
    if {[llength [info commands ::dui::platform::rescale_x]]} {
        return [::dui::platform::rescale_x $v]
    }
    return [expr {int($v * double($L(physical_screen_w)) / $L(screen_w))}]
}

proc ::plugins::ShotHistoryEditor::_text_px {font text} {
    if {[llength [info commands font]] && [lsearch -exact [font names] $font] >= 0} {
        return [font measure $font $text]
    }
    # No Tk font system (offline test): a generous 11 px per character.
    return [expr {[string length $text] * 11}]
}

# One line that fits width_v (virtual), cut with "..." when it does not.
# Line breaks inside the text become " / ".
proc ::plugins::ShotHistoryEditor::_fit_line {text font width_v} {
    set text [string map [list "\r" "" "\n" " / "] [string trim $text]]
    set max [_phys_w $width_v]
    if {[_text_px $font $text] <= $max} { return $text }
    set lo 0
    set hi [string length $text]
    while {$hi - $lo > 1} {
        set mid [expr {($lo + $hi) / 2}]
        if {[_text_px $font "[string range $text 0 [expr {$mid - 1}]]..."] <= $max} {
            set lo $mid
        } else {
            set hi $mid
        }
    }
    return "[string trimright [string range $text 0 [expr {$lo - 1}]]]..."
}

# Word-wraps text into at most maxlines lines of width_v; the last kept
# line ends in "..." when text was left out.
proc ::plugins::ShotHistoryEditor::_wrap_lines {text font width_v maxlines} {
    set max [_phys_w $width_v]
    set out {}
    foreach para [split [string map [list "\r" ""] [string trim $text]] "\n"] {
        set line ""
        foreach word [split [string trim $para] " "] {
            if {$word eq ""} { continue }
            set try [_pick [expr {$line eq ""}] $word "$line $word"]
            if {$line ne "" && [_text_px $font $try] > $max} {
                lappend out $line
                set line $word
            } else {
                set line $try
            }
        }
        if {$line ne ""} { lappend out $line }
    }
    if {[llength $out] > $maxlines} {
        set rest [join [lrange $out [expr {$maxlines - 1}] end] " "]
        set out [lrange $out 0 [expr {$maxlines - 2}]]
        set last [_fit_line "$rest " $font $width_v]
        if {![string match "*..." $last]} { set last "[string trimright $last]..." }
        lappend out $last
    }
    return [join [lmap l $out { _fit_line $l $font $width_v }] "\n"]
}

# "30 Sep", "18-23 Sep", "31 Jul - 7 Aug", or with years when either end is
# not in the current year.
proc ::plugins::ShotHistoryEditor::_fmt_span {first last} {
    if {![string is integer -strict $first] || ![string is integer -strict $last]} { return "" }
    if {$first > $last} { lassign [list $first $last] last first }
    set this_year [clock format [clock seconds] -format %Y]
    foreach w {first last} {
        set t [set $w]
        set d($w) [string trimleft [clock format $t -format %d] 0]
        set m($w) [clock format $t -format %b]
        set y($w) [clock format $t -format %Y]
    }
    set ys [_pick [expr {$y(first) eq $this_year && $y(last) eq $this_year}] "" " $y(last)"]
    if {$y(first) eq $y(last) && $m(first) eq $m(last)} {
        if {$d(first) eq $d(last)} { return "$d(last) $m(last)$ys" }
        return "$d(first)-$d(last) $m(last)$ys"
    }
    if {$y(first) eq $y(last)} {
        return "$d(first) $m(first) - $d(last) $m(last)$ys"
    }
    return "$d(first) $m(first) $y(first) - $d(last) $m(last) $y(last)"
}

# String choice without expr: expr's ?: hands numeric-looking strings back
# in canonical form ("1." -> "1.0", "1.50" -> "1.5", " 2025" -> "2025"),
# so any branch that can carry text or user data goes through this.
proc ::plugins::ShotHistoryEditor::_pick {cond a b} {
    if {$cond} { return $a }
    return $b
}

proc ::plugins::ShotHistoryEditor::_plural {n one many} {
    return "$n [_pick [expr {$n == 1}] $one $many]"
}

# v0.16.1 (tablet-found): the tile's date chip. "Roasted 2026-09-20" was cut
# to "Roasted 2026-..."; an ISO date now reads "Roasted 20 Sep" (another
# year: "Roasted Sep 2025"), anything else is shown as typed. Parsed with
# regexp and scan, so a malformed date never raises (no caught error).
proc ::plugins::ShotHistoryEditor::_roast_chip_text {date} {
    if {![regexp {^([0-9]{4})-([0-9]{2})-([0-9]{2})$} $date -> y m d]} { return $date }
    set mon [lindex {Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec} [expr {[scan $m %d] - 1}]]
    if {$mon eq "" || [scan $d %d] < 1 || [scan $d %d] > 31} { return $date }
    if {$y eq [clock format [clock seconds] -format %Y]} {
        return "[translate Roasted] [scan $d %d] $mon"
    }
    return "[translate Roasted] $mon $y"
}

# Every visible row with the bag fields, newest first: the card list's
# source and filters (read-only handle, removed column, trash manifest,
# edit overlay), without its LIMIT.
proc ::plugins::ShotHistoryEditor::_load_bag_rows {} {
    variable last_error
    set rows {}
    set last_error ""
    set db [_open_ro_db]
    if {$db eq ""} { return $rows }
    set table [_choose_source $db]
    if {$table eq ""} {
        set last_error "No SDB shot table or V_shot view detected."
        _close_db
        return $rows
    }
    set cols [_columns $db $table]
    set aliases {clock filename profile_title bean_brand bean_type bean_notes roast_level roast_date beverage_type file_modification_date}
    set select_parts [lmap a $aliases { _select_expr $cols $a $a }]
    set sql "SELECT [join $select_parts {, }] FROM [_q $table]"
    if {[_has_col $cols removed]} {
        append sql " WHERE (removed IS NULL OR removed=0)"
    }
    if {[_has_col $cols clock]} {
        append sql " ORDER BY [_q clock] DESC"
    } elseif {[_has_col $cols filename]} {
        append sql " ORDER BY [_q filename] DESC"
    }
    set deleted [_deleted_filenames_dict]
    set overlays [_all_edit_overlays]
    if {[catch {
        $db eval $sql row {
            if {[dict exists $deleted $row(filename)]} { continue }
            set item {}
            foreach a $aliases { dict set item $a $row($a) }
            lappend rows [_apply_edit_overlay $item $overlays]
        }
    } err]} {
        set last_error "Could not read shots for the Bags view: $err"
    }
    _close_db
    return $rows
}

# Diagnostics: which of the Bags view's columns the SDB source has (a
# missing one reads as empty; nothing assumes the schema).
proc ::plugins::ShotHistoryEditor::_bag_field_detect {} {
    set db [_open_ro_db]
    if {$db eq ""} { return "SDB not readable" }
    set table [_choose_source $db]
    if {$table eq ""} {
        _close_db
        return "no shot table or view"
    }
    set cols [_columns $db $table]
    _close_db
    set out {}
    foreach c {bean_brand bean_type bean_notes roast_level roast_date beverage_type} {
        lappend out "$c [_pick [_has_col $cols $c] yes no]"
    }
    return [join $out ", "]
}

# Groups rows (newest first) into bags keyed by the trimmed roaster and bag
# name. Each bag: roaster, name, key, files (one dict per file: filename,
# clock, cleaning and the five bag fields), shots, cleaning, first/last
# (oldest/newest shot clock), show (the newest shot -- the values the tile
# and the editor show) and editable (0 for the no-roaster-no-name group).
proc ::plugins::ShotHistoryEditor::_group_bags {rows} {
    set order {}
    array set g {}
    foreach r $rows {
        set brand [string trim [_dget $r bean_brand]]
        set type [string trim [_dget $r bean_type]]
        set key [list $brand $type]
        if {![info exists g($key)]} {
            lappend order $key
            set g($key) [dict create roaster $brand name $type key $key files {} \
                shots 0 cleaning 0 first "" last "" show ""]
        }
        set clean [_is_cleaning_row $r]
        set f [dict create filename [_dget $r filename] clock [_dget $r clock] cleaning $clean]
        foreach k {bean_brand bean_type bean_notes roast_level roast_date} {
            dict set f $k [string trim [_dget $r $k]]
        }
        dict lappend g($key) files $f
        if {$clean} {
            dict incr g($key) cleaning
            continue
        }
        dict incr g($key) shots
        if {[dict get $g($key) show] eq ""} { dict set g($key) show $f }
        set c [_dget $r clock]
        if {[string is integer -strict $c]} {
            if {[dict get $g($key) last] eq ""} { dict set g($key) last $c }
            dict set g($key) first $c
        }
    }
    set out {}
    foreach key $order {
        set b $g($key)
        if {[dict get $b show] eq ""} { dict set b show [lindex [dict get $b files] 0] }
        if {[dict get $b last] eq ""} {
            foreach f [dict get $b files] {
                set c [dict get $f clock]
                if {![string is integer -strict $c]} { continue }
                if {[dict get $b last] eq ""} { dict set b last $c }
                dict set b first $c
            }
        }
        dict set b editable [expr {[lindex $key 0] ne "" || [lindex $key 1] ne ""}]
        lappend out $b
    }
    return $out
}

# Is this bag the one the next shot will be saved with? Exact trimmed
# roaster + name, as bags are grouped here (v0.18.0; was any letter case and
# either source, which flagged a bag a disabled DYE still named).
proc ::plugins::ShotHistoryEditor::_bag_in_use {b} {
    if {![dict get $b editable]} { return 0 }
    set n [_bag_next_source]
    if {[dict get $n source] eq "none"} { return 0 }
    return [expr {[dict get $b key] eq [list [dict get $n bean_brand] [dict get $n bean_type]]}]
}

# value -> number of files, over every file of the bag (cleaning runs too:
# a bag edit writes them as well).
proc ::plugins::ShotHistoryEditor::_bag_field_counts {b field} {
    set counts [dict create]
    foreach f [dict get $b files] {
        dict incr counts [_dget $f $field]
    }
    return $counts
}

proc ::plugins::ShotHistoryEditor::_bag_labels {b} {
    if {![dict get $b editable]} {
        return [list [translate "Shots with no roaster or bag name"] [translate "No bag recorded"]]
    }
    set roaster [dict get $b roaster]
    set name [dict get $b name]
    if {$roaster eq ""} { set roaster [translate "No roaster"] }
    if {$name eq ""} { set name [translate "No bag name"] }
    return [list $roaster $name]
}

proc ::plugins::ShotHistoryEditor::_roast_dot {level} {
    variable L
    switch -- [string tolower $level] {
        light          { return "#e2c08d" }
        medium-light   { return "#c99a62" }
        medium         { return "#a5703f" }
        medium-dark    { return "#7d4c2a" }
        dark           { return "#55321c" }
    }
    return $L(dot_unknown)
}

# Shows or hides plain items by exact tag; -initial 1 so the state survives
# the framework's re-show on the next page load (the page-show flash trap).
proc ::plugins::ShotHistoryEditor::_vis {page tags on} {
    foreach t $tags {
        if {$on} {
            catch { dui item show $page $t -initial 1 }
        } else {
            catch { dui item hide $page $t -initial 1 }
        }
    }
}

# ---- Shots | Bags switch (toolbar row of the main page and the Bags page) -----

# v0.18.1 (owner mockup): one rounded box at left_x in the toolbar row with
# the two sides inside it; the box is drawn first so the sides sit on it.
proc ::plugins::ShotHistoryEditor::_add_view_tabs {page active} {
    variable L
    set x0 $L(left_x)
    set y0 $L(toolbar_y0)
    set y1 $L(toolbar_y1)
    set in $L(seg_inset)
    rounded_rect $page $x0 $y0 [expr {$x0 + $L(seg_w)}] $y1 $L(seg_radius) \
        -fill $L(seg_bg) -outline $L(seg_outline) -width 2 -tags she_tabs_bg
    set w [expr {($L(seg_w) - 3 * $in) / 2}]
    set sx [expr {$x0 + $in}]
    dui add dbutton $page $sx [expr {$y0 + $in}] [expr {$sx + $w}] [expr {$y1 - $in}] -tags she_tab_shots \
        -label [translate "Shots"] -command ::plugins::ShotHistoryEditor::tab_shots_click \
        -label_font $L(font_button) -style she_btn -radius $L(seg_btn_radius)
    set sx [expr {$sx + $w + $in}]
    dui add dbutton $page $sx [expr {$y0 + $in}] [expr {$sx + $w}] [expr {$y1 - $in}] -tags she_tab_bags \
        -label [translate "Bags"] -command ::plugins::ShotHistoryEditor::tab_bags_click \
        -label_font $L(font_button) -style she_btn -radius $L(seg_btn_radius)
    _paint_view_tabs $page $active
}

# The side of the page you are on is filled like a button with a bold
# label; the other side is the box itself with a plain label (muted while
# disabled: Bags in Select mode).
proc ::plugins::ShotHistoryEditor::_paint_view_tabs {page active} {
    variable L
    catch { dui item config $page she_tabs_bg -fill $L(seg_bg) -outline $L(seg_outline) }
    foreach {t name} {she_tab_shots shots she_tab_bags bags} {
        set on [expr {$name eq $active}]
        set fill [_pick $on $L(btn_fill) $L(seg_bg)]
        set ink [_pick $on $L(btn_label_fill) $L(text_body)]
        set font [_pick $on $L(font_button) $L(font_body)]
        catch { dui item config $page ${t}-btn -fill $fill -outline $fill \
            -disabledfill $L(seg_bg) -disabledoutline $L(seg_bg) }
        catch { dui item config $page ${t}-lbl -fill $ink -disabledfill $L(btn_label_disabled) -font $font }
    }
}

# Select mode stays on the Shots tab: Bags is disabled while it is on.
proc ::plugins::ShotHistoryEditor::_refresh_view_tabs {page} {
    variable select_mode
    catch { dui item enable_or_disable [expr {!$select_mode}] $page she_tab_bags* -initial 1 }
}

proc ::plugins::ShotHistoryEditor::tab_shots_click {} {
    if {[_page_is_current ShotHistoryEditor_bags]} {
        _return_to_page ShotHistoryEditor_settings
    }
}

proc ::plugins::ShotHistoryEditor::tab_bags_click {} {
    variable select_mode
    variable bag_offset
    if {$select_mode || ![_page_is_current ShotHistoryEditor_settings]} { return }
    set bag_offset 0
    open_page ShotHistoryEditor_bags
}

# Done on the Bags tab leaves the plugin, as on the Shots tab.
proc ::plugins::ShotHistoryEditor::bags_done {} {
    variable _settings_return_page
    if {![_bag_flow_settled]} { return }
    _navigate_done $_settings_return_page
}

# ---- Main page: cleaning-run cards ------------------------------------------

proc ::plugins::ShotHistoryEditor::_paint_main_clean_pills {} {
    variable L
    variable card_page_size
    set page ShotHistoryEditor_settings
    for {set i 0} {$i < $card_page_size} {incr i} {
        catch { dui item config $page row${i}_clean_bg -fill $L(clean_pill_bg) -outline $L(clean_pill_bg) }
        catch { dui item config $page row${i}_clean_txt -fill $L(clean_pill_text) }
    }
}

# ---- Bags page ------------------------------------------------------------

proc ::plugins::ShotHistoryEditor::_bag_tile_box {i} {
    variable L
    set x0 [expr {$L(left_x) + ($i % $L(bag_cols)) * ($L(bag_tile_w) + $L(md))}]
    set y0 [expr {$L(list_top) + ($i / $L(bag_cols)) * ($L(bag_tile_h) + $L(md))}]
    return [list $x0 $y0 [expr {$x0 + $L(bag_tile_w)}] [expr {$y0 + $L(bag_tile_h)}]]
}

# The text widths of a tile (virtual): line (full inner width), roaster
# (clear of the IN USE pill), footer (clear of the Edit bag button).
proc ::plugins::ShotHistoryEditor::_bag_tile_widths {} {
    variable L
    set inner [expr {$L(bag_tile_w) - 2 * $L(card_pad_x)}]
    return [list $inner [expr {$inner - $L(bag_pill_w) - $L(md)}] \
        [expr {$inner - $L(bag_btn_w) - $L(md)}]]
}

# The Bags page from SDB (plus the edit overlay). A bag Save whose result
# page could not be shown leaves its first line for the status, once.
proc ::plugins::ShotHistoryEditor::refresh_bags_page {page} {
    variable bag_list
    variable bag_result_unseen
    set bag_list [_group_bags [_load_bag_rows]]
    _paint_bags_page $page
    if {$bag_result_unseen ne "" && [_page_is_current $page]} {
        catch { dui item config $page bags_status -text "[translate {Last bag save}]: $bag_result_unseen" }
        set bag_result_unseen ""
    }
}

proc ::plugins::ShotHistoryEditor::_bags_shown {} {
    variable bag_list
    variable bag_offset
    variable bag_page_size
    set total [llength $bag_list]
    if {$total <= 0} {
        set bag_offset 0
    } else {
        set max_offset [expr {(($total - 1) / $bag_page_size) * $bag_page_size}]
        if {$bag_offset > $max_offset} { set bag_offset $max_offset }
    }
    if {$bag_offset < 0} { set bag_offset 0 }
    return [list $total [lrange $bag_list $bag_offset [expr {$bag_offset + $bag_page_size - 1}]]]
}

proc ::plugins::ShotHistoryEditor::scroll_bags {delta} {
    variable bag_offset
    variable bag_page_size
    incr bag_offset [expr {$delta * $bag_page_size}]
    if {$bag_offset < 0} { set bag_offset 0 }
    _paint_bags_page ShotHistoryEditor_bags
}

# Paints the Bags page from the cached bag_list (no database read).
proc ::plugins::ShotHistoryEditor::_paint_bags_page {page} {
    variable bag_offset
    variable bag_page_size
    variable last_error
    lassign [_bags_shown] total shown
    if {$total == 0} {
        set status [translate "No bags found."]
        if {$last_error ne ""} { append status " $last_error" }
    } else {
        set status "Showing [expr {$bag_offset + 1}]-[expr {$bag_offset + [llength $shown]}] of [_plural $total bag bags], newest first."
    }
    catch { dui item config $page bags_status -text $status }
    for {set i 0} {$i < $bag_page_size} {incr i} {
        if {$i < [llength $shown]} {
            _paint_bag_tile $page $i [lindex $shown $i]
        } else {
            _hide_bag_tile $page $i
        }
    }
    # The pager's -state writes are live canvas state: only on the page on
    # screen (a theme switch elsewhere repaints this page from the cache).
    if {[_page_is_current $page]} {
        _set_pager_state $page bags_prev bags_next [expr {$bag_offset > 0}] \
            [expr {$bag_offset + [llength $shown] < $total}]
    }
}

proc ::plugins::ShotHistoryEditor::_hide_bag_tile {page i} {
    variable bag_tile_parts
    _vis $page [lmap p $bag_tile_parts { string cat bag${i}_ $p }] 0
    _vis $page [list bag${i}_edit*] 0
}

proc ::plugins::ShotHistoryEditor::_paint_bag_tile {page i b} {
    variable L
    variable bag_tile_parts
    set p bag${i}_
    lassign [_bag_tile_widths] w_line w_roaster w_footer
    set in_use [_bag_in_use $b]
    set editable [dict get $b editable]
    set show [dict get $b show]
    lassign [_bag_labels $b] roaster name

    catch { dui item config $page ${p}bg -fill $L(card_bg) \
        -outline [expr {$in_use ? $L(value_blue) : $L(card_outline)}] }
    catch { dui item config $page ${p}roaster -text [_fit_line $roaster $L(font_caption) $w_roaster] -fill $L(text_mut) }
    catch { dui item config $page ${p}name -text [_fit_line $name $L(font_section) $w_line] -fill $L(text_hi) }
    catch { dui item config $page ${p}pill_bg -fill $L(inuse_bg) -outline $L(inuse_bg) }
    catch { dui item config $page ${p}pill_txt -fill $L(inuse_text) }

    # Roast level and roast date chips: filled when set, outlined "+ ..."
    # when missing (the details a bag edit is for).
    set lvl [_dget $show roast_level]
    if {$lvl ne ""} {
        catch { dui item config $page ${p}lvl_bg -fill $L(chip_bg) -outline $L(chip_bg) }
        catch { dui item config $page ${p}lvl_txt -fill $L(text_hi) \
            -text [_fit_line $lvl $L(font_caption) [expr {$L(bag_lvl_chip_w) - $L(bag_dot_dx) - 2 * $L(bag_dot_r) - 2 * $L(sm)}]] }
        catch { dui item config $page ${p}lvl_dot -fill [_roast_dot $lvl] -outline $L(dot_outline) }
    } else {
        catch { dui item config $page ${p}lvl_bg -fill $L(card_bg) -outline $L(chip_missing) }
        catch { dui item config $page ${p}lvl_txt -fill $L(text_mut) -text [translate "+ Roast level"] }
    }
    set date [_dget $show roast_date]
    if {$date ne ""} {
        catch { dui item config $page ${p}date_bg -fill $L(chip_bg) -outline $L(chip_bg) }
        catch { dui item config $page ${p}date_txt -fill $L(text_hi) \
            -text [_fit_line [_roast_chip_text $date] $L(font_caption) [expr {$L(bag_date_chip_w) - 2 * $L(sm)}]] }
    } else {
        catch { dui item config $page ${p}date_bg -fill $L(card_bg) -outline $L(chip_missing) }
        catch { dui item config $page ${p}date_txt -fill $L(text_mut) -text [translate "+ Roast date"] }
    }

    set notes [_dget $show bean_notes]
    if {!$editable} {
        catch { dui item config $page ${p}notes -fill $L(text_mut) \
            -text [_wrap_lines [translate "Edit these one at a time from the Shots list."] $L(font_caption) $w_line 2] }
    } elseif {$notes ne ""} {
        catch { dui item config $page ${p}notes -fill $L(text_body) -text [_wrap_lines $notes $L(font_caption) $w_line 2] }
    } else {
        catch { dui item config $page ${p}notes -fill $L(text_mut) -text [translate "No notes yet"] }
    }

    # Footer, one fact per line: shots, when, cleaning runs.
    set count [_plural [dict get $b shots] shot shots]
    catch { dui item config $page ${p}count -fill $L(text_body) -text [_fit_line $count $L(font_body) $w_footer] }
    set span [_fmt_span [dict get $b first] [dict get $b last]]
    catch { dui item config $page ${p}span -fill $L(text_mut) -text [_fit_line $span $L(font_caption) $w_footer] }
    set nc [dict get $b cleaning]
    set clean [_pick [expr {$nc > 0}] "+[_plural $nc {cleaning run} {cleaning runs}]" ""]
    catch { dui item config $page ${p}clean -fill $L(clean_text) -text [_fit_line $clean $L(font_caption) $w_footer] }

    set shown_parts {}
    foreach part $bag_tile_parts {
        if {$part in {pill_bg pill_txt} && !$in_use} { continue }
        if {$part eq "lvl_dot" && $lvl eq ""} { continue }
        lappend shown_parts ${p}$part
    }
    _vis $page [lmap part $bag_tile_parts { string cat $p $part }] 0
    _vis $page $shown_parts 1
    _vis $page [list ${p}edit*] 1
    catch { dui item enable_or_disable $editable $page ${p}edit* -initial 1 }
}

# ---- Edit bag page (preview) -------------------------------------------------

proc ::plugins::ShotHistoryEditor::_bag_edit_var {field} {
    switch -- $field {
        bean_brand  { return ::plugins::ShotHistoryEditor::bag_edit_roaster }
        bean_type   { return ::plugins::ShotHistoryEditor::bag_edit_name }
        bean_notes  { return ::plugins::ShotHistoryEditor::bag_edit_notes }
        roast_date  { return ::plugins::ShotHistoryEditor::bag_edit_date }
        roast_level { return ::plugins::ShotHistoryEditor::bag_edit_level }
    }
    return ""
}

proc ::plugins::ShotHistoryEditor::_bag_edit_value {field} {
    set v [_bag_edit_var $field]
    if {$v eq "" || ![info exists $v]} { return "" }
    return [string trim [set $v]]
}

# Loads one bag into the editor: every field starts at the bag's newest
# shot's value, so an untouched field is never written.
proc ::plugins::ShotHistoryEditor::_bag_edit_begin {b} {
    variable bag_cur
    variable bag_fields
    set bag_cur $b
    set show [dict get $b show]
    foreach {field label} $bag_fields {
        set [_bag_edit_var $field] [_dget $show $field]
    }
}

# Forward into the editor: the page is painted for THIS bag before it loads
# (a load re-shows the last visit's items before show runs).
proc ::plugins::ShotHistoryEditor::bag_edit_open {i} {
    if {![_bag_flow_settled]} { return }
    lassign [_bags_shown] total shown
    if {$i < 0 || $i >= [llength $shown]} { return }
    set b [lindex $shown $i]
    if {![dict get $b editable]} { return }
    _bag_edit_begin $b
    _paint_bag_edit ShotHistoryEditor_bag_edit
    open_page ShotHistoryEditor_bag_edit
    _bag_flow_mark
}

# The editor opened with no bag chosen -- only possible by loading the page
# directly (the DevBridge harness): it shows the newest bag, read-only as
# everything here.
proc ::plugins::ShotHistoryEditor::_bag_default_pick {} {
    variable bag_cur
    variable bag_list
    if {$bag_cur ne ""} { return }
    if {[llength $bag_list] == 0} { set bag_list [_group_bags [_load_bag_rows]] }
    foreach b $bag_list {
        if {[dict get $b editable]} {
            _bag_edit_begin $b
            msg -INFO "ShotHistoryEditor: Edit bag opened without a choice; showing the newest bag"
            return
        }
    }
}

# One dict per bag field: field label orig new changed counts, where orig is
# the value the editor started from and counts covers every file.
proc ::plugins::ShotHistoryEditor::_bag_changes {} {
    variable bag_cur
    variable bag_fields
    set out {}
    if {$bag_cur eq ""} { return $out }
    set show [dict get $bag_cur show]
    foreach {field label} $bag_fields {
        set orig [string trim [_dget $show $field]]
        set new [_bag_edit_value $field]
        lappend out [dict create field $field label $label orig $orig new $new \
            changed [expr {$new ne $orig}] counts [_bag_field_counts $bag_cur $field]]
    }
    return $out
}

proc ::plugins::ShotHistoryEditor::_bag_change_count {} {
    set n 0
    foreach c [_bag_changes] { if {[dict get $c changed]} { incr n } }
    return $n
}

proc ::plugins::ShotHistoryEditor::_bag_file_total {b} {
    return [llength [dict get $b files]]
}

proc ::plugins::ShotHistoryEditor::_bag_summary_line {b} {
    lassign [_bag_labels $b] roaster name
    set line "$roaster  [_u 0xb7]  $name  [_u 0xb7]  [_plural [dict get $b shots] shot shots]"
    set nc [dict get $b cleaning]
    if {$nc > 0} { append line " + [_plural $nc {cleaning run} {cleaning runs}]" }
    return $line
}

proc ::plugins::ShotHistoryEditor::bag_pick_level {k} {
    variable bag_levels
    variable bag_edit_level
    if {$k < 0 || $k >= [llength $bag_levels]} { return }
    set bag_edit_level [lindex $bag_levels $k]
    _paint_bag_edit_state ShotHistoryEditor_bag_edit
}

proc ::plugins::ShotHistoryEditor::bag_hide_keyboard {} {
    catch { dui platform hide_android_keyboard }
    catch { focus [dui canvas] }
}

# Variable traces and the notes box's key releases call this while typing.
proc ::plugins::ShotHistoryEditor::_bag_edit_trace {args} {
    if {[catch { _paint_bag_edit_state ShotHistoryEditor_bag_edit } err]} {
        msg -ERROR "ShotHistoryEditor: Edit bag state refresh failed: $err"
    }
}

proc ::plugins::ShotHistoryEditor::_paint_bag_levels {page} {
    variable L
    variable bag_levels
    set cur [_bag_edit_value roast_level]
    set k 0
    foreach lv $bag_levels {
        set on [expr {[string tolower $lv] eq [string tolower $cur]}]
        set fill [expr {$on ? $L(choice_on_fill) : $L(btn_fill)}]
        set ink [expr {$on ? $L(choice_on_label) : $L(btn_label_fill)}]
        catch { dui item config $page bag_lvl${k}-btn -fill $fill -outline $fill \
            -disabledfill $L(btn_disabled_fill) -disabledoutline $L(btn_disabled_fill) }
        catch { dui item config $page bag_lvl${k}-lbl -fill $ink }
        incr k
    }
}

proc ::plugins::ShotHistoryEditor::_paint_bag_edit_state {page} {
    variable L
    variable bag_cur
    set changes [_bag_changes]
    set n 0
    foreach c $changes {
        set field [dict get $c field]
        set tag [dict get {bean_brand bag_st_roaster bean_type bag_st_name bean_notes bag_st_notes roast_date bag_st_date roast_level bag_st_level} $field]
        set counts [dict get $c counts]
        if {[dict get $c changed]} {
            incr n
            set p [_bag_value_problem $field [dict get $c new]]
            if {$p ne ""} {
                set text "[translate {Not allowed}]: $p" ; set role danger
            } else {
                set text [translate "Changed"] ; set role value_blue
            }
        } elseif {[dict size $counts] > 1} {
            set text [translate "Differs between files; the newest is shown"] ; set role warn
        } else {
            set text "" ; set role text_mut
        }
        if {$field eq "roast_level" && ![dict get $c changed]} {
            set cur [dict get $c orig]
            set known 0
            foreach lv $::plugins::ShotHistoryEditor::bag_levels {
                if {[string tolower $lv] eq [string tolower $cur]} { set known 1 }
            }
            if {!$known} { set text "[translate Now]: $cur" ; set role text_mut }
        }
        catch { dui item config $page $tag -text $text -fill $L($role) }
    }
    _paint_bag_levels $page
    if {$bag_cur eq ""} {
        set lbl [translate "Review changes"]
    } elseif {$n == 0} {
        set lbl [translate "No changes yet"]
    } else {
        set lbl "[translate Review] [_plural $n change changes]"
    }
    catch { dui item config $page bag_edit_review -label $lbl }
    catch { dui item enable_or_disable [expr {$bag_cur ne "" && $n > 0}] $page bag_edit_review* -initial 1 }
}

proc ::plugins::ShotHistoryEditor::_paint_bag_edit {page} {
    variable L
    variable bag_cur
    set col_w [expr {$L(content_w) / 3 - 2 * $L(card_pad_x)}]
    if {$bag_cur eq ""} {
        catch { dui item config $page subtitle -text [translate "No bag selected. Open one from the Bags view."] }
        foreach k {0 1 2} {
            catch { dui item config $page bag_info_v$k -text "" }
            catch { dui item config $page bag_info_d$k -text "" }
        }
        _paint_bag_edit_state $page
        return
    }
    set b $bag_cur
    catch { dui item config $page subtitle -text [_fit_line [_bag_summary_line $b] $L(font_caption) $L(content_w)] }
    set span [_fmt_span [dict get $b first] [dict get $b last]]
    set nfiles [_bag_file_total $b]
    catch { dui item config $page bag_info_v0 -text [_plural [dict get $b shots] shot shots] }
    catch { dui item config $page bag_info_d0 -text [_wrap_lines \
        "[_pick [expr {$span ne ""}] "$span. " ""][translate {Only the fields you change are written, to all}] [_plural $nfiles file files]." \
        $L(font_caption) $col_w 3] }
    set nc [dict get $b cleaning]
    if {$nc > 0} {
        catch { dui item config $page bag_info_v1 -text [_plural $nc {cleaning run} {cleaning runs}] }
        catch { dui item config $page bag_info_d1 -text [_wrap_lines \
            [translate "Cleaning runs carry the bag that was loaded, so they change with it and stay in this bag."] \
            $L(font_caption) $col_w 3] }
    } else {
        catch { dui item config $page bag_info_v1 -text [translate "No cleaning runs"] }
        catch { dui item config $page bag_info_d1 -text [_wrap_lines \
            [translate "None of this bag's files is a cleaning run."] $L(font_caption) $col_w 3] }
    }
    catch { dui item config $page bag_info_v2 -text [translate "Shot data"] }
    catch { dui item config $page bag_info_d2 -text [_wrap_lines \
        [translate "Grind, dose, yield, time, profile and the shot curves."] $L(font_caption) $col_w 3] }
    _paint_bag_edit_state $page
}

# Back to Bags: repainted from the cached list first (close_dialog shows the
# page without its load hook).
proc ::plugins::ShotHistoryEditor::bag_edit_back {} {
    variable bag_plan
    if {![_bag_flow_settled]} { return }
    set bag_plan {}
    _paint_bags_page ShotHistoryEditor_bags
    _return_to_page ShotHistoryEditor_bags
    _bag_flow_mark
}

# Forward into Review: the snapshot is built here, once (it reads every file
# of the bag), and the page painted from it before it loads.
proc ::plugins::ShotHistoryEditor::bag_review_open {} {
    variable bag_cur
    if {![_bag_flow_settled] || $bag_cur eq "" || [_bag_change_count] == 0} { return }
    bag_hide_keyboard
    _bag_plan_build
    _paint_bag_review ShotHistoryEditor_bag_review
    open_page ShotHistoryEditor_bag_review
    _bag_flow_mark
}

# ---- Review bag changes page (v0.17.0: Save opens the typed confirmation) --

proc ::plugins::ShotHistoryEditor::_bag_now_text {c nfiles} {
    set counts [dict get $c counts]
    if {[dict size $counts] == 1} {
        set v [lindex [dict keys $counts] 0]
        if {$v eq ""} { return "[translate empty] ([translate all] [_plural $nfiles file files])" }
        return "$v ([translate all] [_plural $nfiles file files])"
    }
    set text "[dict size $counts] [translate {different values}]"
    if {[dict exists $counts ""]} { append text ", [dict get $counts {}] [translate empty]" }
    return $text
}

# Plain-language warnings about what the change would do, most important
# first: a merge, the bag in use, Grind Advisor's per-roast-date bags, a
# non-ISO date. (Blocking conditions are _bag_save_blocker's.)
proc ::plugins::ShotHistoryEditor::_bag_review_warnings {changes} {
    variable bag_cur
    variable bag_list
    set warn {}
    if {$bag_cur eq ""} { return $warn }
    array set new {}
    array set chg {}
    foreach c $changes {
        set new([dict get $c field]) [dict get $c new]
        set chg([dict get $c field]) [dict get $c changed]
    }
    if {($chg(bean_brand) || $chg(bean_type)) && ($new(bean_brand) ne "" || $new(bean_type) ne "")} {
        set key_lc [list [string tolower $new(bean_brand)] [string tolower $new(bean_type)]]
        foreach b $bag_list {
            if {![dict get $b editable] || [dict get $b key] eq [dict get $bag_cur key]} { continue }
            if {[list [string tolower [dict get $b roaster]] [string tolower [dict get $b name]]] eq $key_lc} {
                lassign [_bag_labels $b] r n
                lappend warn "[translate {Joins the bag}] $r [_u 0xb7] $n ([_plural [_bag_file_total $b] file files]): [translate {the two become one bag, for Grind Advisor too.}]"
                break
            }
        }
    }
    set ch [dict create]
    foreach c $changes {
        if {[dict get $c changed]} { dict set ch [dict get $c field] [dict get $c new] }
    }
    set np [_bag_next_preview [dict get $bag_cur key] $ch [_bag_value_sets $bag_cur]]
    if {[dict get $np status] eq "update" && [_dye_next_api]} {
        set w "[translate {Loaded for your next shot: Save updates it too}] ([join [lmap f [dict keys [dict get $np new]] { _bag_next_label $f }] {, }])"
        if {[dict size [dict get $np kept]]} {
            append w "; [translate {it keeps its own}] [join [lmap f [dict keys [dict get $np kept]] { _bag_next_label $f }] {, }]"
        }
        lappend warn "$w."
    } elseif {[dict get $np status] ne "none"} {
        lappend warn "[translate {Loaded for your next shot, which keeps the old details until you load the bag again}]: [_bag_reload_hint $np]."
    }
    if {$chg(roast_date)} {
        set dates {}
        foreach f [dict get $bag_cur files] {
            if {[dict get $f cleaning]} { continue }
            set d [string tolower [string trim [dict get $f roast_date]]]
            if {$d ne "" && $d ni $dates} { lappend dates $d }
        }
        if {[llength $dates] > 1} {
            lappend warn "[translate {Grind Advisor and Lumen see}] [llength $dates] [translate {bags here, one per roast date: one date joins their grind data.}]"
        }
    }
    if {$chg(roast_date) && $new(roast_date) ne "" && ![regexp {^[0-9]{4}-[0-9]{2}-[0-9]{2}$} $new(roast_date)]} {
        lappend warn [translate "The roast date is not YYYY-MM-DD; it is saved exactly as typed."]
    }
    return $warn
}

proc ::plugins::ShotHistoryEditor::_paint_bag_review {page} {
    variable L
    variable bag_cur
    variable bag_plan
    set w_field [expr {$L(rv_x_now) - $L(card_pad_x) - $L(lg)}]
    set w_now [expr {$L(rv_x_after) - $L(rv_x_now) - $L(lg)}]
    set w_after [expr {$L(content_w) - $L(rv_x_after) - $L(card_pad_x)}]
    set panel_w [expr {($L(content_w) - $L(md)) / 2 - 2 * $L(card_pad_x)}]
    set changes [_bag_changes]
    if {$bag_cur eq "" || $bag_plan eq ""} {
        catch { dui item config $page subtitle -text [translate "No bag selected. Open one from the Bags view."] }
        for {set k 0} {$k < 5} {incr k} {
            _vis $page [list rv_f$k rv_n$k rv_a$k rv_d$k] 0
        }
        catch { dui item config $page rv_warn -text "" }
        catch { dui item config $page rv_fl_title -text [translate "Files"] }
        catch { dui item config $page rv_fl_text -text "" }
        catch { dui item config $page rv_fl_more -text "" }
        catch { dui item config $page rv_do_text -text "" }
        catch { dui item config $page rv_do_note -text "" }
        catch { dui item config $page rv_save -label [translate "Save"] }
        catch { dui item enable_or_disable 0 $page rv_save* -initial 1 }
        return
    }
    set b $bag_cur
    set nfiles [_bag_file_total $b]
    set nc [dict get $b cleaning]
    catch { dui item config $page subtitle -text [_fit_line [_bag_summary_line $b] $L(font_caption) $L(content_w)] }

    set k 0
    set labels {}
    foreach c $changes {
        set on [dict get $c changed]
        if {$on} { lappend labels [translate [dict get $c label]] }
        set now [_bag_now_text $c $nfiles]
        set after [translate unchanged]
        if {$on} { set after [_pick [expr {[dict get $c new] eq ""}] [translate empty] [dict get $c new]] }
        catch { dui item config $page rv_f$k -text [_fit_line [translate [dict get $c label]] $L(font_primary) $w_field] \
            -fill [expr {$on ? $L(text_hi) : $L(text_mut)}] }
        catch { dui item config $page rv_n$k -text [_fit_line $now $L(font_body) $w_now] \
            -fill [expr {$on ? $L(text_body) : $L(text_mut)}] }
        catch { dui item config $page rv_a$k -text [_fit_line $after $L(font_body) $w_after] \
            -fill [expr {$on ? $L(value_blue) : $L(text_mut)}] }
        catch { dui item config $page rv_d$k -fill $L(card_outline) -outline $L(card_outline) }
        _vis $page [list rv_f$k rv_n$k rv_a$k rv_d$k] 1
        incr k
    }
    catch { dui item config $page rv_warn -fill $L(warn) -text [join [_bag_warning_lines 2] "\n"] }

    set n [dict get $bag_plan to_change]
    set which [_pick [llength $labels] [join $labels ", "] [translate "changed"]]
    set steps {}
    foreach s [list \
        "1. [translate {Back up all}] [_plural $n file files] [translate {to backups/ and check each copy.}]" \
        "2. [translate {Rewrite only the}] $which [translate {lines in each file.}]" \
        "3. [translate {Check each file; a failed check restores its backup.}]" \
        "4. [translate {Log each file, update its history_v2 copy; never SDB.}]"] {
        lappend steps [_wrap_lines $s $L(font_body) $panel_w 2]
    }
    set np [_bag_next_for_plan]
    if {$np ne "" && [dict get $np status] eq "update" && [_dye_next_api]} {
        lappend steps [_wrap_lines "5. [translate {Update your next shot through DYE.}]" $L(font_body) $panel_w 2]
    }
    set steps [split [join $steps "\n"] "\n"]
    catch { dui item config $page rv_do_text -text [join [lrange $steps 0 [expr {$L(rv_fl_lines) - 1}]] "\n"] }
    catch { dui item config $page rv_do_note -fill $L(text_mut) -text [_wrap_lines \
        "[translate {Nothing is written until you type the number of files on the next page.}][_bag_v2_note [dict get $bag_plan files]]" \
        $L(font_caption) $panel_w 2] }

    # Files, newest first, each with what Save would do to it.
    set lines {}
    set nshow $L(rv_fl_lines)
    foreach f [lrange [dict get $bag_plan files] 0 [expr {$nshow - 1}]] {
        set line "[_fmt_time [dict get $f clock]]   [dict get $f filename].shot"
        switch -- [dict get $f status] {
            unchanged { append line "   ([translate {up to date}])" }
            skipped   { append line "   ([translate skipped])" }
            default   { if {[dict get $f cleaning]} { append line "   ([translate cleaning])" } }
        }
        lappend lines [_fit_line $line $L(font_body) $panel_w]
    }
    set title [_plural $nfiles file files]
    if {$nc > 0} { append title " ([_plural $nc {cleaning run} {cleaning runs}])" }
    catch { dui item config $page rv_fl_title -text $title }
    catch { dui item config $page rv_fl_text -text [join $lines "\n"] }
    set more ""
    if {[llength [dict get $bag_plan files]] > $nshow} {
        set more "+ [expr {[llength [dict get $bag_plan files]] - $nshow}] [translate more]. "
    }
    if {[dict get $bag_plan blocker] eq ""} {
        append more "[translate {To change}]: $n. [translate {Up to date}]: [dict get $bag_plan unchanged]. [translate Skipped]: [dict get $bag_plan skipped]."
    }
    catch { dui item config $page rv_fl_more -text [_wrap_lines $more $L(font_caption) $panel_w 2] }
    set ok [expr {[dict get $bag_plan blocker] eq "" && $n > 0 && [_bag_plan_matches]}]
    catch { dui item config $page rv_save -label [_pick $ok "[translate Save] [_plural $n file files]..." [translate "Nothing to save"]] }
    catch { dui item enable_or_disable $ok $page rv_save* -initial 1 }
}

proc ::plugins::ShotHistoryEditor::bag_review_back {} {
    variable bag_plan
    if {![_bag_flow_settled]} { return }
    set bag_plan {}
    _paint_bag_edit ShotHistoryEditor_bag_edit
    _return_to_page ShotHistoryEditor_bag_edit
    _bag_flow_mark
}

# Repaints what the shared registries do not cover (backgrounds, headers,
# Backs and pagers are repainted by _retheme_all itself): the Bags pages'
# texts, panels, entries and buttons, the main page's tabs and cleaning
# pills, all from cached data only. The Confirm page's Save keeps its
# danger label (painted after the button loop).
proc ::plugins::ShotHistoryEditor::_retheme_bag_pages {} {
    variable L
    foreach {p tag role} {
        ShotHistoryEditor_bags bags_status text_mut
        ShotHistoryEditor_bag_edit bag_lbl_roaster text_mut
        ShotHistoryEditor_bag_edit bag_lbl_name text_mut
        ShotHistoryEditor_bag_edit bag_lbl_notes text_mut
        ShotHistoryEditor_bag_edit bag_lbl_date text_mut
        ShotHistoryEditor_bag_edit bag_hint_date text_mut
        ShotHistoryEditor_bag_edit bag_lbl_level text_mut
        ShotHistoryEditor_bag_edit bag_info_h0 text_mut
        ShotHistoryEditor_bag_edit bag_info_h1 clean_text
        ShotHistoryEditor_bag_edit bag_info_h2 text_mut
        ShotHistoryEditor_bag_edit bag_info_v0 text_hi
        ShotHistoryEditor_bag_edit bag_info_v1 text_hi
        ShotHistoryEditor_bag_edit bag_info_v2 text_hi
        ShotHistoryEditor_bag_edit bag_info_d0 text_mut
        ShotHistoryEditor_bag_edit bag_info_d1 text_mut
        ShotHistoryEditor_bag_edit bag_info_d2 text_mut
        ShotHistoryEditor_bag_review rv_h_field text_mut
        ShotHistoryEditor_bag_review rv_h_now text_mut
        ShotHistoryEditor_bag_review rv_h_after text_mut
        ShotHistoryEditor_bag_review rv_do_title text_hi
        ShotHistoryEditor_bag_review rv_do_text text_body
        ShotHistoryEditor_bag_review rv_do_note text_mut
        ShotHistoryEditor_bag_review rv_fl_title text_hi
        ShotHistoryEditor_bag_review rv_fl_text text_body
        ShotHistoryEditor_bag_review rv_fl_more text_mut
        ShotHistoryEditor_bag_confirm bc_changes text_body
        ShotHistoryEditor_bag_confirm bc_warn warn
        ShotHistoryEditor_bag_confirm bc_instr text_body
        ShotHistoryEditor_bag_confirm bc_error danger
        ShotHistoryEditor_bag_confirm bc_files text_body
        ShotHistoryEditor_bag_result br_text text_body
    } {
        catch { dui item config $p $tag -fill $L($role) }
    }
    foreach {p tag} {
        ShotHistoryEditor_bag_edit bag_info_bg
        ShotHistoryEditor_bag_review rv_do_bg
        ShotHistoryEditor_bag_review rv_fl_bg
        ShotHistoryEditor_bag_confirm bc_panel_bg
    } {
        catch { dui item config $p $tag -fill $L(card_bg) -outline $L(card_outline) }
    }
    foreach {p tag} {
        ShotHistoryEditor_bag_edit bag_info_div1
        ShotHistoryEditor_bag_edit bag_info_div2
        ShotHistoryEditor_bag_review rv_div_head
    } {
        catch { dui item config $p $tag -fill $L(card_outline) -outline $L(card_outline) }
    }
    foreach t {bag_ent_roaster bag_ent_name bag_ent_date bag_ent_notes} {
        catch { dui item config ShotHistoryEditor_bag_edit $t \
            -bg $L(entry_bg) -foreground $L(text_hi) -insertbackground $L(text_hi) }
    }
    catch { dui item config ShotHistoryEditor_bag_confirm bc_entry \
        -bg $L(entry_danger_bg) -foreground $L(danger) -insertbackground $L(danger) }
    variable bag_page_size
    set bag_btns {btn_theme bags_done}
    for {set i 0} {$i < $bag_page_size} {incr i} { lappend bag_btns bag${i}_edit }
    foreach {p tags} [list \
        ShotHistoryEditor_bags $bag_btns \
        ShotHistoryEditor_bag_edit {bag_hidekb bag_edit_review} \
        ShotHistoryEditor_bag_review {rv_save} \
        ShotHistoryEditor_bag_confirm {bc_cancel bc_save bc_hidekb} \
        ShotHistoryEditor_bag_result {br_done}] {
        foreach t $tags {
            catch { dui item config $p ${t}-btn \
                -fill $L(btn_fill) -outline $L(btn_fill) \
                -disabledfill $L(btn_disabled_fill) -disabledoutline $L(btn_disabled_fill) }
            catch { dui item config $p ${t}-lbl -fill $L(btn_label_fill) }
        }
    }
    catch { dui item config ShotHistoryEditor_bag_confirm bc_save-lbl -fill $L(danger) }
    catch { dui item config ShotHistoryEditor_bags btn_theme -label [_theme_button_face] }
    _paint_view_tabs ShotHistoryEditor_settings shots
    _paint_view_tabs ShotHistoryEditor_bags bags
    _paint_main_clean_pills
    _paint_bags_page ShotHistoryEditor_bags
    _paint_bag_edit ShotHistoryEditor_bag_edit
    _paint_bag_review ShotHistoryEditor_bag_review
    _paint_bag_confirm ShotHistoryEditor_bag_confirm
    _paint_bag_result ShotHistoryEditor_bag_result
}


namespace eval ::plugins::ShotHistoryEditor {
    # v0.17.0: the bag Save (write capability 7).
    # The snapshot Review shows, Confirm types against and Save re-checks.
    variable bag_plan {}
    variable bag_confirm_input ""
    variable bag_confirm_error ""
    # Clock ms while a Save runs; counts as running for 10 minutes at most,
    # so a lost reset can never block the buttons for good.
    variable bag_save_running 0
    variable bag_result_text ""
    # 1 when the last Save wrote at least one file (Done then goes to Bags;
    # otherwise back to Edit bag with the edits kept).
    variable bag_result_wrote 0
    # The last result's first line when its page could not be shown (the app
    # had moved to a machine page); the Bags status shows it once.
    variable bag_result_unseen ""
    # Clock ms of the last page change in the bag flow: a tap within 700 ms of
    # it is a repeat queued while a slow step ran, and is ignored (the next
    # page's button sits where the last one was). A time, not a flag.
    variable bag_flow_opened 0
    # 1 only between Review's Save button and the end of a submit or a
    # Cancel: Confirm arms nothing it was not opened for (a direct load).
    variable bag_confirm_armed 0
}

# ---------------------------------------------------------------------------
# v0.17.0 -- .shot text surgery for the bag Save (write capability 7). Pure
# procs: no file access, no dui. A .shot file is a Tcl dict (the app reads it
# with `array set`; SDB's modify_shot_file writes each setting as
# "<tab>[list $k] [list $v]"), so entries are found the way Tcl's list
# parser reads them -- lines accumulated until `info complete` -- which
# handles values that span lines (bean_notes) and the long read_only_backup
# value, unlike the one-line-per-key scan of the v0.5.0 single-field save.
# The file is handled as BYTES: every byte outside the replaced entries is
# copied from the original, and a file whose UTF-8 does not round-trip
# exactly is refused (every .shot carries raw BLE bytes).
# ---------------------------------------------------------------------------

# Top-level entries of a .shot text given as lines (no newlines in them),
# from line index `from` to `to`: a list of {key first last} line ranges,
# or an error message string.
proc ::plugins::ShotHistoryEditor::_shot_chunks {lines from to} {
    set out {}
    set i $from
    while {$i <= $to} {
        set first $i
        set chunk [lindex $lines $i]
        if {[string trim $chunk] eq ""} {
            incr i
            continue
        }
        # An incomplete chunk can only complete on a line that closes a brace
        # or a quote, or after a line ending in a backslash, so `info
        # complete` (which rescans the whole chunk) runs only then: the
        # settings block is one top-level chunk of ~300 lines.
        set done [info complete $chunk]
        while {!$done && $i < $to} {
            set prev [lindex $lines $i]
            incr i
            set line [lindex $lines $i]
            append chunk "\n" $line
            if {[string first "\}" $line] >= 0 || [string first "\"" $line] >= 0 ||
                [string index $prev end] eq "\\"} {
                set done [info complete $chunk]
            }
        }
        if {!$done} {
            return "an entry starting at line [expr {$first + 1}] never closes"
        }
        set t [string trim $chunk]
        if {![string is list $t] || [llength $t] != 2} {
            return "the entry at line [expr {$first + 1}] is not one key and one value"
        }
        lappend out [list [lindex $t 0] $first $i]
        incr i
    }
    return $out
}

# Locates the settings block and its entries. Returns a dict:
# ok 1 settings_first settings_last entries (key first last triples), or
# ok 0 message <why>.
proc ::plugins::ShotHistoryEditor::_shot_settings_layout {lines} {
    set top [_shot_chunks $lines 0 [expr {[llength $lines] - 1}]]
    if {[llength $top] == 0 || [llength [lindex $top 0]] != 3} {
        return [dict create ok 0 message [_pick [llength $top] $top "the file is empty"]]
    }
    set hits [lsearch -all -index 0 -exact $top settings]
    if {[llength $hits] != 1} {
        return [dict create ok 0 message "[llength $hits] top-level settings entries (need exactly one)"]
    }
    lassign [lindex $top [lindex $hits 0]] - sfirst slast
    if {[string trim [lindex $lines $sfirst]] ne "settings \{" || [string trim [lindex $lines $slast]] ne "\}"} {
        return [dict create ok 0 message "the settings block is not laid out one entry per line"]
    }
    set inner [_shot_chunks $lines [expr {$sfirst + 1}] [expr {$slast - 1}]]
    if {[llength $inner] && [llength [lindex $inner 0]] != 3} {
        return [dict create ok 0 message "settings: $inner"]
    }
    return [dict create ok 1 settings_first $sfirst settings_last $slast entries $inner]
}

# Applies changes (dict key -> new value) to the raw BYTES of a .shot file.
# Returns dict ok 1 bytes <new bytes> text <original text> new_text <new
# text> settings <original settings dict> old <key -> old value>, or ok 0
# message <why>. Each changed key must exist exactly once directly in the
# settings block; its line range becomes one entry in the app's own form
# (leading whitespace kept, [list key] [list value]); all other bytes are
# copied unchanged from raw.
proc ::plugins::ShotHistoryEditor::_shot_apply_changes {raw changes} {
    set text [encoding convertfrom utf-8 $raw]
    if {[encoding convertto utf-8 $text] ne $raw} {
        return [dict create ok 0 message "the file is not plain UTF-8 (it would not be rewritten byte for byte)"]
    }
    if {![string is list $text] || [llength $text] % 2} {
        return [dict create ok 0 message "the file is not a key/value list"]
    }
    set top [dict create {*}$text]
    if {![dict exists $top settings]} {
        return [dict create ok 0 message "the file has no settings"]
    }
    set settings [dict get $top settings]
    if {![string is list $settings] || [llength $settings] % 2} {
        return [dict create ok 0 message "the settings are not a key/value list"]
    }
    set settings [dict create {*}$settings]
    set lines [split $text "\n"]
    set lay [_shot_settings_layout $lines]
    if {![dict get $lay ok]} { return $lay }
    # Byte offset of the start of every line (each line is followed by one
    # newline byte, except possibly the last).
    set offs {}
    set pos 0
    foreach line $lines {
        lappend offs $pos
        incr pos [expr {[string length [encoding convertto utf-8 $line]] + 1}]
    }
    set ranges {}
    set old [dict create]
    dict for {key new} $changes {
        set found [lsearch -all -index 0 -exact [dict get $lay entries] $key]
        if {[llength $found] != 1} {
            return [dict create ok 0 message "$key appears [llength $found] times in the settings block"]
        }
        lassign [lindex [dict get $lay entries] [lindex $found 0]] - first last
        dict set old $key [dict get $settings $key]
        regexp {^[ \t]*} [lindex $lines $first] ws
        set b0 [lindex $offs $first]
        set b1 [expr {[lindex $offs $last] + [string length [encoding convertto utf-8 [lindex $lines $last]]] - 1}]
        lappend ranges [list $b0 $b1 [encoding convertto utf-8 "$ws[list $key] [list $new]"]]
    }
    set bytes $raw
    foreach r [lsort -integer -decreasing -index 0 $ranges] {
        lassign $r b0 b1 rep
        set bytes [string replace $bytes $b0 $b1 $rep]
    }
    return [dict create ok 1 bytes $bytes text $text new_text [encoding convertfrom utf-8 $bytes] \
        settings $settings old $old]
}

# Proves new_text differs from orig_text only by the changed settings:
# both parse as even-length lists with the same top-level keys in the same
# order, every top-level value but settings is string-equal, and settings
# has the same keys in the same order with every unchanged value equal and
# every changed value equal to its new value. Returns "" or the reason.
proc ::plugins::ShotHistoryEditor::_shot_verify_edit {orig_text new_text changes} {
    foreach {name t} [list original $orig_text new $new_text] {
        if {![string is list $t] || [llength $t] % 2} { return "the $name text is not a key/value list" }
    }
    if {[llength $orig_text] != [llength $new_text]} { return "top-level entry count changed" }
    foreach {ok ov} $orig_text {nk nv} $new_text {
        if {$ok ne $nk} { return "top-level key order changed ($ok / $nk)" }
        if {$ok ne "settings"} {
            if {$ov ne $nv} { return "top-level $ok changed" }
            continue
        }
        foreach {name t} [list original $ov new $nv] {
            if {![string is list $t] || [llength $t] % 2} { return "the $name settings are not a key/value list" }
        }
        if {[llength $ov] != [llength $nv]} { return "settings entry count changed" }
        foreach {sk sv} $ov {tk tv} $nv {
            if {$sk ne $tk} { return "settings key order changed ($sk / $tk)" }
            if {[dict exists $changes $sk]} {
                if {$tv ne [dict get $changes $sk]} { return "$sk is not the new value" }
            } elseif {$sv ne $tv} {
                return "$sk changed although it was not edited"
            }
        }
    }
    return ""
}

# ---------------------------------------------------------------------------
# v0.17.0 -- bag Save, WRITE CAPABILITY 7. Rewrites the changed bag fields
# (bean_brand, bean_type, bean_notes, roast_date, roast_level) in every
# history/<f>.shot file of one bag -- cleaning runs included (owner
# 2026-10-01) -- after the typed file count on the confirm page. The write
# path is documented in full in CHANGELOG v0.17.0. In short, per Save:
# re-check every file against the snapshot (nothing written if the set
# changed); a write-ahead BEGIN line in edit_log.txt; a verified whole-file
# backup of EVERY file into backups/<ts>_<batch>_bag/ before the first
# write; then per file: new bytes to a temp file in that backup folder,
# read back, `file rename` into history/, read back, `file mtime` (SDB
# resync); a failed read-back copies the backup over and checks it; its
# edit_log line and edit_manifest records right after it; stop at the first
# failure; an END line; one _notify_downstream. SDB and history_v2 are never
# written. No `file delete` anywhere in this capability.
# ---------------------------------------------------------------------------

# Manifest / log value escaping: the manifest is "|"-separated, one record
# per line, and bean_notes holds both ("Peru | Washed | Bourbon" + newline).
# Decoding is ONE string map with all four pairs (sequential maps corrupt a
# literal backslash followed by n or p).
proc ::plugins::ShotHistoryEditor::_esc {v} {
    return [string map [list "\\" "\\\\" "|" "\\p" "\n" "\\n" "\r" "\\r"] $v]
}

proc ::plugins::ShotHistoryEditor::_unesc {v} {
    return [string map [list "\\\\" "\\" "\\p" "|" "\\n" "\n" "\\r" "\r"] $v]
}

# A path directly inside history/ (the purge path's _inside_trash_dir shape).
proc ::plugins::ShotHistoryEditor::_inside_history_dir {path} {
    set root [file normalize [history_path]]
    set p [file normalize $path]
    return [expr {[string first "$root/" $p] == 0 && [file dirname $p] eq $root}]
}

# A path inside the plugin's backups/ folder.
proc ::plugins::ShotHistoryEditor::_inside_backups_dir {path} {
    set root [file normalize [backups_dir]]
    return [expr {[string first "$root/" [file normalize $path]] == 0}]
}

proc ::plugins::ShotHistoryEditor::_read_bytes {path} {
    set fh [open $path r]
    fconfigure $fh -translation binary
    set raw [read $fh]
    close $fh
    return $raw
}

# The file's bytes, or "" when it cannot be read (a comparison then fails).
proc ::plugins::ShotHistoryEditor::_read_bytes_or_empty {path} {
    if {![file isfile $path] || ![file readable $path]} { return "" }
    if {[catch { set raw [_read_bytes $path] } err]} {
        msg -ERROR "ShotHistoryEditor: could not read back $path: $err"
        return ""
    }
    return $raw
}

proc ::plugins::ShotHistoryEditor::_write_bytes {path bytes} {
    set fh [open $path w]
    fconfigure $fh -translation binary
    puts -nonewline $fh $bytes
    close $fh
}

# Appends one line; 1 when it is on disk, 0 (logged) when not.
proc ::plugins::ShotHistoryEditor::_bag_append {path line} {
    if {[catch {
        set fh [open $path a]
        fconfigure $fh -encoding utf-8
        puts $fh $line
        close $fh
    } err]} {
        if {[info exists fh]} { catch { close $fh } }
        msg -ERROR "ShotHistoryEditor: could not append to $path: $err"
        return 0
    }
    return 1
}

proc ::plugins::ShotHistoryEditor::_bag_log {line} {
    return [_bag_append [edit_log_path] $line]
}

# One manifest record per changed field, 7 parts (the 7th, e1, marks the
# escaped values); _edit_manifest_records reads both forms.
proc ::plugins::ShotHistoryEditor::_bag_manifest {ts epoch filename field old new backup_path} {
    return [_bag_append [edit_manifest_path] \
        "$ts|$filename|$field|[_esc $old]|[_esc $new]|$backup_path|e1|$epoch"]
}

proc ::plugins::ShotHistoryEditor::_bag_fields_text {d} {
    set parts {}
    dict for {k v} $d { lappend parts "$k=[_esc $v]" }
    return [join $parts " "]
}

# Is an SDB sync running right now? Copied from Grind Advisor v3.16.8
# (_sdb_busy): SDB's updating_db counts only while populate / create /
# upgrade is really on the call stack (a failed sync leaves the flag at 1).
proc ::plugins::ShotHistoryEditor::_sdb_busy {} {
    if {![info exists ::plugins::SDB::updating_db] \
     || $::plugins::SDB::updating_db != 1} { return 0 }
    for {set i [info frame]} {$i >= 1} {incr i -1} {
        set f [info frame $i]
        if {[dict exists $f proc] && [dict get $f proc] in {
                ::plugins::SDB::populate ::plugins::SDB::create
                ::plugins::SDB::upgrade}} { return 1 }
    }
    return 0
}

# "" when the DE1 is disconnected or resting, else the state to report.
# DevBridge v0.3.0's machine_busy, copied: ::de1(device_handle) is 0 when
# disconnected; ::de1_num_state names ::de1(state); unreadable fails closed.
proc ::plugins::ShotHistoryEditor::_machine_busy {} {
    set handle "unknown"
    if {[info exists ::de1(device_handle)]} { set handle $::de1(device_handle) }
    if {$handle eq "0"} { return "" }
    set name ""
    if {[info exists ::de1(state)] && [info exists ::de1_num_state($::de1(state))]} {
        set name $::de1_num_state($::de1(state))
    }
    if {$name in {Idle Sleep GoingToSleep}} { return "" }
    return [_pick [expr {$name eq ""}] "unknown" $name]
}

# What a typed value may not hold (the v0.5.0 single-field save and the
# plugin's readers count braces line by line, so a brace or a backslash
# in a value would break them for that file).
proc ::plugins::ShotHistoryEditor::_bag_value_problem {field v} {
    if {[regexp {[\{\}\\]} $v]} { return [translate "can't contain braces or a backslash"] }
    if {[string first "\r" $v] >= 0} { return [translate "can't contain a carriage return"] }
    if {$field ne "bean_notes" && [string first "\n" $v] >= 0} { return [translate "must be one line"] }
    return ""
}

# "" when the open bag may be saved, else why not (shown on Review and
# Confirm; checked again by perform_bag_save before any file is touched).
proc ::plugins::ShotHistoryEditor::_bag_save_blocker {} {
    variable bag_cur
    if {$bag_cur eq ""} { return [translate "No bag is open."] }
    # v0.22.0: backups and logs go to SHE's folder (see _she_write_blocker).
    set why [_she_write_blocker]
    if {$why ne ""} { return "[string toupper [string index $why 0]][string range $why 1 end]." }
    set n 0
    set id_changed 0
    array set new {}
    foreach c [_bag_changes] {
        set new([dict get $c field]) [dict get $c new]
        if {![dict get $c changed]} { continue }
        incr n
        if {[dict get $c field] in {bean_brand bean_type}} { set id_changed 1 }
        set p [_bag_value_problem [dict get $c field] [dict get $c new]]
        if {$p ne ""} { return "[translate [dict get $c label]] $p." }
    }
    if {$n == 0} { return [translate "Nothing has changed."] }
    if {$new(bean_brand) eq "" && $new(bean_type) eq ""} {
        return [translate "A bag needs a roaster or a bag name."]
    }
    # A new roaster + name that matches another bag in all but letter case
    # would stay a separate bag here (bags group by exact spelling) while
    # Grind Advisor and SDB join them: it must be typed exactly. Only a
    # roaster or name change is checked (a case twin made by another tool
    # can still have its notes, date and level saved).
    if {!$id_changed} { return "" }
    variable bag_list
    set key [list $new(bean_brand) $new(bean_type)]
    set key_lc [list [string tolower $new(bean_brand)] [string tolower $new(bean_type)]]
    foreach b $bag_list {
        if {![dict get $b editable] || [dict get $b key] eq [dict get $bag_cur key] || [dict get $b key] eq $key} { continue }
        if {[list [string tolower [dict get $b roaster]] [string tolower [dict get $b name]]] eq $key_lc} {
            lassign [_bag_labels $b] r n
            return "[translate {another bag is spelled}] $r [_u 0xb7] $n: [translate {type it exactly that way to join it.}]"
        }
    }
    return ""
}

# The bag the next shot will be saved with, read-only. While DYE is loaded
# its next-shot plan wins: its shot-start hook copies next_* over ::settings
# (DYE.tcl ~722-733). Otherwise the app's ::settings. Returns dict source
# dye | settings | none plus the five bag fields, trimmed.
proc ::plugins::ShotHistoryEditor::_bag_next_source {} {
    set fields {bean_brand bean_type bean_notes roast_date roast_level}
    set out [dict create source none]
    if {[llength [info commands ::plugins::loaded]] && [::plugins::loaded DYE] &&
        [info exists ::plugins::DYE::settings(next_bean_brand)] &&
        [info exists ::plugins::DYE::settings(next_bean_type)]} {
        dict set out source dye
        foreach f $fields {
            set v ""
            if {[info exists ::plugins::DYE::settings(next_$f)]} { set v [string trim $::plugins::DYE::settings(next_$f)] }
            dict set out $f $v
        }
    } elseif {[info exists ::settings(bean_brand)] && [info exists ::settings(bean_type)]} {
        dict set out source settings
        foreach f $fields {
            set v ""
            if {[info exists ::settings($f)]} { set v [string trim $::settings($f)] }
            dict set out $f $v
        }
    }
    return $out
}

# A bag's values of the fields that may differ between its files (notes,
# roast date, roast level): field -> the distinct trimmed values over all its
# files, cleaning runs included.
proc ::plugins::ShotHistoryEditor::_bag_value_sets {b} {
    set out [dict create bean_notes {} roast_date {} roast_level {}]
    if {$b eq ""} { return $out }
    foreach f [dict get $b files] {
        foreach k {bean_notes roast_date roast_level} {
            set v [string trim [_dget $f $k]]
            if {$v ni [dict get $out $k]} { dict lappend out $k $v }
        }
    }
    return $out
}

# What a bag save of `changes` (field -> new value) on the bag `key` (vals:
# its _bag_value_sets) would change in the next-shot plan. Read-only.
# status: none (the next shot is another bag, or already has these values),
# update (DYE's plan names this bag: v0.19.0 applies it, _bag_next_apply),
# manual (the app settings name it and DYE is not loaded: SHE never writes
# ::settings, so only a manual reload helps). old / new: the fields that
# would change; kept: changed fields the plan holds its OWN value for (none
# of the bag's files has it), left as they are.
# A plan whose roast date none of the bag's files carry is another physical
# bag of the same coffee (Grind Advisor and Lumen key a bag by roast date
# too; e.g. a newer bag just scanned): none, it is never touched.
proc ::plugins::ShotHistoryEditor::_bag_next_preview {key changes vals} {
    set n [_bag_next_source]
    set out [dict create status none source [dict get $n source] old {} new {} kept {}]
    if {[dict get $n source] eq "none" || [llength $key] != 2} { return $out }
    if {$key ne [list [dict get $n bean_brand] [dict get $n bean_type]]} { return $out }
    set pd [dict get $n roast_date]
    if {$pd ne "" && $pd ni [_dget $vals roast_date]} { return $out }
    set old [dict create]
    set new [dict create]
    set kept [dict create]
    dict for {f v} $changes {
        if {![dict exists $n $f]} { continue }
        set pv [dict get $n $f]
        if {$pv eq [string trim $v]} { continue }
        if {$f in {bean_notes roast_date roast_level} && $pv ni [_dget $vals $f]} {
            dict set kept $f $pv
            continue
        }
        dict set old $f $pv
        dict set new $f [string trim $v]
    }
    dict set out kept $kept
    if {[dict size $new] == 0} { return $out }
    dict set out old $old
    dict set out new $new
    dict set out status [_pick [expr {[dict get $n source] eq "dye"}] update manual]
    return $out
}

# DYE's next-shot calls that BeanScanner (its one write path) and Lumen's bag
# arrows already use on the tablet.
proc ::plugins::ShotHistoryEditor::_dye_next_api {} {
    return [expr {[llength [info commands ::plugins::DYE::shots::get_next]] &&
                  [llength [info commands ::plugins::DYE::shots::source_next_from]]}]
}

# ---------------------------------------------------------------------------
# v0.19.0 WRITE CAPABILITY 8 (owner 2026-10-02: "Yes, update it"; previewed
# in v0.18.x and tested on the tablet first). After a bag Save that wrote at
# least one file, when DYE is loaded and its next-shot plan names EXACTLY the
# saved bag, the fields this save changed (and only those that differ in the
# plan) are applied to the plan with BeanScanner's proven call:
#   array set nx [::plugins::DYE::shots::get_next]; set nx(clock) 0
#   set nx(<field>) <new> for each changed field
#   ::plugins::DYE::shots::source_next_from {} nx <fields>
# DYE then sets next_<field> and ::settings(<field>), saves the app settings
# and its own, marks the plan modified and rebuilds its description; it does
# not touch grind, dose, profile or the plan's source shot (a selected DYE
# favourite may be deselected, as with a BeanScanner scan or a Lumen arrow).
# Runs BEFORE _notify_downstream, so Grind Advisor computes for the new bag
# and Lumen lights its dot. Refused while the DE1 is busy or SDB syncs.
# Write-ahead: a "BAGSAVE NEXT BEGIN" line (old and new plan values) must be
# in edit_log.txt before the call; "BAGSAVE NEXT OK | FAILED" follows with
# what the plan holds afterwards (post-check of every applied field). SHE
# itself never writes ::settings or DYE's settings array.
# ---------------------------------------------------------------------------

# Returns dict status applied | failed | skipped | manual | none, why, old,
# new (the fields and values concerned), kept (fields the plan keeps).
proc ::plugins::ShotHistoryEditor::_bag_next_apply {key changes vals ts batch} {
    set p [_bag_next_preview $key $changes $vals]
    set out [dict create status [dict get $p status] why "" old [dict get $p old] new [dict get $p new] kept [dict get $p kept]]
    switch -- [dict get $p status] {
        none { return $out }
        manual {
            _bag_log "$ts BAGSAVE NEXT SKIPPED batch=$batch status=manual old: [_bag_fields_text [dict get $p old]] (DYE is not loaded; the app settings keep the old details)"
            return $out
        }
    }
    set new [dict get $p new]
    set fields [dict keys $new]
    set why ""
    if {![_dye_next_api]} {
        set why [translate "DYE's next-shot calls are missing"]
    } elseif {[_machine_busy] ne "" || [_sdb_busy]} {
        set why [translate "the DE1 or the shot database is busy"]
    }
    if {$why ne ""} {
        _bag_log "$ts BAGSAVE NEXT SKIPPED batch=$batch reason=[_esc $why]"
        dict set out status skipped
        dict set out why $why
        return $out
    }
    if {[catch { array set nx [::plugins::DYE::shots::get_next] } err]} {
        msg -ERROR "ShotHistoryEditor: could not read DYE's next shot after the bag save: $err"
        _bag_log "$ts BAGSAVE NEXT SKIPPED batch=$batch reason=[_esc "get_next failed: $err"]"
        dict set out status skipped
        dict set out why [translate "DYE's next shot could not be read"]
        return $out
    }
    # get_next leaves clock empty; source_next_from compares it numerically.
    set nx(clock) 0
    dict for {f v} $new { set nx($f) $v }
    set kept_txt ""
    if {[dict size [dict get $p kept]]} { set kept_txt " kept: [_bag_fields_text [dict get $p kept]]" }
    if {![_bag_log "$ts BAGSAVE NEXT BEGIN batch=$batch fields=[join $fields ,] old: [_bag_fields_text [dict get $p old]] new: [_bag_fields_text $new]$kept_txt"]} {
        dict set out status skipped
        dict set out why [translate "edit_log.txt could not be written"]
        return $out
    }
    set rc 0
    if {[catch { set rc [::plugins::DYE::shots::source_next_from {} nx $fields] } err]} {
        msg -ERROR "ShotHistoryEditor: DYE refused the next-shot update after the bag save: $err"
        set why "DYE: $err"
    } elseif {$rc != 1} {
        set why [translate "DYE did not apply it"]
    }
    set now [dict create]
    foreach f $fields {
        set v ""
        if {[info exists ::plugins::DYE::settings(next_$f)]} { set v [string trim $::plugins::DYE::settings(next_$f)] }
        dict set now $f $v
        if {$why eq "" && $v ne [dict get $new $f]} { set why "[translate {the plan reads}] $f=$v" }
    }
    if {$why eq ""} {
        _bag_log "$ts BAGSAVE NEXT OK batch=$batch now: [_bag_fields_text $now]"
        msg -INFO "ShotHistoryEditor: next shot updated after bag save $ts/$batch: [join $fields {, }]"
        dict set out status applied
    } else {
        _bag_log "$ts BAGSAVE NEXT FAILED batch=$batch reason=[_esc $why] now: [_bag_fields_text $now]"
        dict set out status failed
        dict set out why $why
    }
    return $out
}

# How to load the bag again by hand, for a dict with status and new (the
# Review warning and the result). Lumen's arrows load a bag through DYE: from
# a bag missing from its list (renamed, or a new roast date) the first tap of
# either arrow jumps to the bag with the newest shot (skin.tcl cycle_bag), so
# "another bag and back" holds only when the name and date did not change.
# Without DYE neither the arrows nor DYE's Next shot exist.
proc ::plugins::ShotHistoryEditor::_bag_reload_hint {p} {
    if {[_dget $p status] eq "manual"} {
        return [translate "enter the new details again where your skin sets the bean for the next shot (DYE is not loaded, so the next shot takes them from the app settings)"]
    }
    set new [_dget $p new]
    if {[dict exists $new bean_brand] || [dict exists $new bean_type] || [dict exists $new roast_date]} {
        return [translate "on Lumen, tap a bag arrow until this bag shows with its dot lit (or edit DYE's Next shot)"]
    }
    return [translate "on Lumen, arrow to another bag and back to this one (or edit DYE's Next shot)"]
}

# The preview for the open bag and its snapshot's changes ("" when none).
proc ::plugins::ShotHistoryEditor::_bag_next_for_plan {} {
    variable bag_cur
    variable bag_plan
    if {$bag_cur eq "" || $bag_plan eq ""} { return "" }
    return [_bag_next_preview [dict get $bag_cur key] [dict get $bag_plan changes] [_bag_value_sets $bag_cur]]
}

# Field labels for the next-shot lines.
proc ::plugins::ShotHistoryEditor::_bag_next_label {f} {
    set labels [dict create bean_brand Roaster bean_type {Bag name} bean_notes Notes \
        roast_date {Roast date} roast_level {Roast level}]
    return [translate [_pick [dict exists $labels $f] [_dget $labels $f] $f]]
}

# The result page's next-shot block for a _bag_next_apply result a: what
# changed in the plan, or what it still holds and how to load the bag again.
proc ::plugins::ShotHistoryEditor::_bag_next_lines {a} {
    variable L
    set lines {}
    set st [dict get $a status]
    switch -- $st {
        applied { lappend lines [translate "Your next shot now has the new details (DYE's next-shot plan):"] }
        manual  { lappend lines [translate "Your next shot still has the old details:"] }
        default { lappend lines "[translate {Your next shot still has the old details}] ([dict get $a why]):" }
    }
    dict for {f v} [dict get $a new] {
        set o [dict get $a old $f]
        set line "- [_bag_next_label $f]: [_pick [expr {$o eq {}}] [translate empty] $o] -> [_pick [expr {$v eq {}}] [translate empty] $v]"
        lappend lines [_fit_line $line $L(font_body) $L(content_w)]
    }
    dict for {f v} [_dget $a kept] {
        set line "- [_bag_next_label $f]: [translate {kept, the next shot has its own}] ([_pick [expr {$v eq {}}] [translate empty] $v])"
        lappend lines [_fit_line $line $L(font_body) $L(content_w)]
    }
    if {$st ne "applied"} {
        lappend lines "[translate {Load it again}]: [_bag_reload_hint [dict create status [_pick [expr {$st eq {manual}}] manual update] new [dict get $a new]]]."
    }
    return $lines
}

# Everything Save needs to know about one file, read-only: status change |
# unchanged | skipped, reason, and for a change the path, the raw bytes, the
# new bytes and the old values. Used for the snapshot and again at Save.
proc ::plugins::ShotHistoryEditor::_bag_prepare {filename changes key} {
    set out [dict create status skipped reason "" path "" raw "" bytes "" old {}]
    if {![regexp {^[0-9]{8}T[0-9]{6}$} $filename]} {
        dict set out reason [translate "unexpected file name"]
        return $out
    }
    set path [_legacy_file $filename]
    dict set out path $path
    if {![_inside_history_dir $path] || ![file isfile $path] || ![file readable $path]} {
        dict set out reason [translate "not found in history/"]
        return $out
    }
    set raw [_read_bytes_or_empty $path]
    if {$raw eq ""} {
        dict set out reason [translate "could not be read"]
        return $out
    }
    set r [_shot_apply_changes $raw $changes]
    if {![dict get $r ok]} {
        dict set out reason [dict get $r message]
        return $out
    }
    set s [dict get $r settings]
    if {[list [string trim [_dget $s bean_brand]] [string trim [_dget $s bean_type]]] ne $key} {
        dict set out reason [translate "no longer in this bag on disk (SDB is out of date)"]
        return $out
    }
    dict set out raw $raw
    dict set out bytes [dict get $r bytes]
    dict set out old [dict get $r old]
    if {[dict get $r bytes] eq $raw} {
        dict set out status unchanged
        return $out
    }
    set why [_shot_verify_edit [dict get $r text] [dict get $r new_text] $changes]
    if {$why ne ""} {
        dict set out reason "[translate {would not verify}]: $why"
        return $out
    }
    dict set out status change
    return $out
}

# The snapshot: the open bag's changes and every file's status, built once
# when Review opens (Review and Confirm only paint from it; Save checks the
# files again against it).
# The open bag's changed fields as field -> new value, in bag_fields order.
proc ::plugins::ShotHistoryEditor::_bag_current_changes {} {
    set changes [dict create]
    foreach c [_bag_changes] {
        if {[dict get $c changed]} { dict set changes [dict get $c field] [dict get $c new] }
    }
    return $changes
}

# Is the snapshot the one for the open bag and its edits as they are now?
# Review, Confirm and Save all require it, so a page reached without
# bag_review_open (a direct load) can never arm or write an old snapshot.
proc ::plugins::ShotHistoryEditor::_bag_plan_matches {} {
    variable bag_plan
    variable bag_cur
    if {$bag_plan eq "" || $bag_cur eq ""} { return 0 }
    return [expr {[dict get $bag_plan key] eq [dict get $bag_cur key] &&
                  [dict get $bag_plan changes] eq [_bag_current_changes]}]
}

proc ::plugins::ShotHistoryEditor::_bag_flow_settled {} {
    variable bag_flow_opened
    # A clock stepped back counts as settled: the block stays 700 ms at most.
    set d [expr {[clock milliseconds] - $bag_flow_opened}]
    return [expr {$d < 0 || $d >= 700}]
}

proc ::plugins::ShotHistoryEditor::_bag_flow_mark {} {
    variable bag_flow_opened
    set bag_flow_opened [clock milliseconds]
}

proc ::plugins::ShotHistoryEditor::_bag_plan_build {} {
    variable bag_cur
    variable bag_plan
    set changes [_bag_current_changes]
    set blocker [_bag_save_blocker]
    set files {}
    set counts [dict create change 0 unchanged 0 skipped 0]
    if {$bag_cur ne "" && $blocker eq ""} {
        foreach f [dict get $bag_cur files] {
            set p [_bag_prepare [dict get $f filename] $changes [dict get $bag_cur key]]
            dict incr counts [dict get $p status]
            lappend files [dict create filename [dict get $f filename] clock [dict get $f clock] \
                cleaning [dict get $f cleaning] status [dict get $p status] reason [dict get $p reason]]
        }
    }
    set bag_plan [dict create key [_pick [expr {$bag_cur ne ""}] [_dget $bag_cur key] {}] \
        changes $changes blocker $blocker files $files \
        to_change [dict get $counts change] unchanged [dict get $counts unchanged] \
        skipped [dict get $counts skipped]]
    return $bag_plan
}

# One file of a Save, after its verified backup. p = the file's Save-time
# _bag_prepare result (status change: path, raw, bytes, old), so the file is
# not parsed again; it is only re-read and compared byte for byte with the
# bytes that were checked and backed up. Returns dict status ok | skipped |
# failed | restore_failed, reason, old.
proc ::plugins::ShotHistoryEditor::_bag_write_file {p backup tmp} {
    set out [dict create status ok reason "" old [dict get $p old]]
    set path [dict get $p path]
    set expected_raw [dict get $p raw]
    set bytes [dict get $p bytes]
    if {[_read_bytes_or_empty $path] ne $expected_raw} {
        return [dict create status skipped reason [translate "changed on disk after its backup"] old {}]
    }
    if {![_inside_history_dir $path] || ![_inside_backups_dir $tmp] || ![_inside_backups_dir $backup]} {
        return [dict create status failed reason [translate "a path left its folder; nothing written"] old {}]
    }
    if {[catch { _write_bytes $tmp $bytes } err]} {
        return [dict create status failed reason "[translate {temp file not written}] ($err); [translate {original untouched}]" old {}]
    }
    if {[_read_bytes_or_empty $tmp] ne $bytes} {
        return [dict create status failed reason [translate "temp file did not read back; original untouched"] old {}]
    }
    if {[catch { file rename -force -- $tmp $path } err]} {
        if {[_read_bytes_or_empty $path] eq $expected_raw} {
            return [dict create status failed reason "[translate {not renamed into place}] ($err); [translate {original untouched}]" old {}]
        }
        return [_bag_restore $path $backup $expected_raw "[translate {rename failed}] ($err)"]
    }
    if {[_read_bytes_or_empty $path] ne $bytes} {
        return [_bag_restore $path $backup $expected_raw [translate "the written file did not read back"]]
    }
    if {[catch { file mtime $path [clock seconds] } err]} {
        msg -NOTICE "ShotHistoryEditor: could not stamp the modification time of $path: $err (SDB will not see this edit until it is resynced another way)"
    }
    dict set out status ok
    return $out
}

# Puts the verified backup back over a file whose write went wrong, and
# checks it. restore_failed names the intact copy.
proc ::plugins::ShotHistoryEditor::_bag_restore {path backup expected_raw why} {
    if {[catch { file copy -force -- $backup $path } err] || [_read_bytes_or_empty $path] ne $expected_raw} {
        return [dict create status restore_failed old {} \
            reason "$why; [translate {RESTORE FAILED: the intact copy is}] $backup"]
    }
    return [dict create status failed old {} reason "$why; [translate {restored from its backup}]"]
}

# The Save. plan = the snapshot Confirm typed against. Returns dict ok,
# message (why nothing was written, when that is so), written, unchanged,
# skipped, failed, restore_failed (lists; the last three of filename
# reason pairs), not_attempted, backup_dir, ts and batch (once a backup
# folder is named; v0.18.0, for the next-shot preview log line).
proc ::plugins::ShotHistoryEditor::perform_bag_save {plan} {
    set res [dict create ok 0 message "" written {} unchanged {} skipped {} failed {} \
        restore_failed {} not_attempted {} backup_dir "" ts "" batch "" v2 {}]
    set blocker [_bag_save_blocker]
    if {$blocker eq ""} { set blocker [dict get $plan blocker] }
    if {$blocker ne ""} {
        dict set res message "[translate {Not saved}]: $blocker"
        return $res
    }
    set changes [dict get $plan changes]
    set key [dict get $plan key]
    if {[dict size $changes] == 0 || [llength $key] != 2} {
        dict set res message [translate "Nothing to save."]
        return $res
    }
    # Save-time check of every file: the set to write must be exactly the
    # set the count was typed for.
    set planned {}
    set fresh {}
    set prepared [dict create]
    foreach f [dict get $plan files] {
        set fn [dict get $f filename]
        if {[dict get $f status] eq "change"} { lappend planned $fn }
        set p [_bag_prepare $fn $changes $key]
        if {[dict get $p status] eq "change"} {
            lappend fresh $fn
            dict set prepared $fn $p
        }
    }
    if {$fresh ne $planned} {
        dict set res message [translate "The files changed since Review. Go back and open Review again; nothing was written."]
        return $res
    }
    if {[llength $fresh] == 0} {
        dict set res message [translate "Every file is already up to date; nothing was written."]
        return $res
    }
    # Every file's mtime is stamped at or after this second, so SDB rows
    # re-read since then hold this save (the overlay retires on it).
    set epoch [clock seconds]
    set ts [clock format $epoch -format {%Y%m%dT%H%M%S}]
    set batch [_new_batch_id]
    dict set res ts $ts
    dict set res batch $batch
    set dir [file join [backups_dir] "${ts}_${batch}_bag"]
    dict set res backup_dir $dir
    if {![_inside_backups_dir $dir] || [file exists $dir]} {
        dict set res message [translate "The backup folder could not be prepared; nothing was written."]
        return $res
    }
    if {[catch { file mkdir $dir } err]} {
        dict set res message "[translate {Could not create the backup folder}] ($err); [translate {nothing was written.}]"
        return $res
    }
    if {![_bag_log "$ts BAGSAVE BEGIN batch=$batch bag=[_esc [lindex $key 0]]|[_esc [lindex $key 1]] [_bag_fields_text $changes] files=[llength $fresh] backup=$dir"]} {
        dict set res message [translate "edit_log.txt could not be written; nothing was written."]
        return $res
    }
    # Every backup, checked byte for byte, before the first write.
    foreach fn $fresh {
        set p [dict get $prepared $fn]
        set backup [file join $dir "$fn.shot"]
        set err ""
        if {[catch { file copy -- [dict get $p path] $backup } err] || [_read_bytes_or_empty $backup] ne [dict get $p raw]} {
            _bag_log "$ts BAGSAVE STOPPED batch=$batch backup_failed=$fn [_esc $err] written=0"
            dict set res message "[translate {The backup of}] $fn [translate {did not check out; nothing was written.}]"
            return $res
        }
    }
    set i 0
    foreach fn $fresh {
        set p [dict get $prepared $fn]
        set backup [file join $dir "$fn.shot"]
        if {[catch { _bag_write_file $p $backup [file join $dir "$fn.shot.new"] } w]} {
            msg -ERROR "ShotHistoryEditor: bag save of $fn stopped by an error: $w"
            set w [dict create status failed reason "[translate {stopped by an error}]: $w" old {}]
        }
        set st [dict get $w status]
        set reason [dict get $w reason]
        set stop 0
        switch -- $st {
            ok {
                dict lappend res written $fn
                set oldtxt [dict create]
                set logged [_bag_log "$ts BAGSAVE OK file=$fn old: [_bag_fields_text [dict get $w old]] backup=$backup"]
                dict for {field new} $changes {
                    set old [dict get $w old $field]
                    if {$old ne $new && $logged} {
                        set logged [_bag_manifest $ts $epoch $fn $field $old $new $backup]
                    }
                }
                if {!$logged} {
                    dict set res message [translate "edit_log.txt or edit_manifest.txt could not be written; stopped after this file."]
                    set stop 1
                } else {
                    # v0.24.0: the changed fields in this shot's history_v2
                    # copy too; its result never stops or undoes the Save.
                    set v [_v2_save $ts $fn $changes $dir]
                    dict lappend res v2 [list $fn [dict get $v status] [dict get $v reason] [dict get $v backup] [_dget $v log_ok 1]]
                }
            }
            unchanged { dict lappend res unchanged $fn }
            skipped {
                dict lappend res skipped [list $fn $reason]
                _bag_log "$ts BAGSAVE SKIPPED file=$fn reason=[_esc $reason]"
            }
            failed {
                dict lappend res failed [list $fn $reason]
                _bag_log "$ts BAGSAVE FAILED file=$fn reason=[_esc $reason]"
                set stop 1
            }
            restore_failed {
                dict lappend res restore_failed [list $fn $reason]
                _bag_log "$ts BAGSAVE RESTORE_FAILED file=$fn intact_copy=$backup reason=[_esc $reason]"
                set stop 1
            }
            default {
                set reason "[translate {unexpected status}] $st"
                dict lappend res failed [list $fn $reason]
                _bag_log "$ts BAGSAVE FAILED file=$fn reason=[_esc $reason]"
                set stop 1
            }
        }
        incr i
        if {$stop} {
            dict set res not_attempted [lrange $fresh $i end]
            break
        }
    }
    _bag_log "$ts BAGSAVE END batch=$batch written=[llength [dict get $res written]] unchanged=[llength [dict get $res unchanged]] skipped=[llength [dict get $res skipped]] failed=[llength [dict get $res failed]] restore_failed=[llength [dict get $res restore_failed]] not_attempted=[llength [dict get $res not_attempted]]"
    dict set res ok [expr {[dict get $res message] eq "" && [llength [dict get $res failed]] == 0 &&
                           [llength [dict get $res restore_failed]] == 0}]
    msg -INFO "ShotHistoryEditor: bag save $ts/$batch wrote [llength [dict get $res written]] of [llength $fresh] files"
    return $res
}

# The warning lines for a page, ready to show: the blocker first, then the
# warnings in priority order, each wrapped to at most two lines of the
# content width; at most max lines in all. A warning that does not fit
# whole gets one cut line, and a last line says how many more follow.
# Files a roaster, name or roast-date change would leave in the old bag:
# the snapshot's skipped files, when the snapshot is for the current edits.
proc ::plugins::ShotHistoryEditor::_bag_left_behind {} {
    variable bag_plan
    if {$bag_plan eq "" || [dict get $bag_plan blocker] ne "" || ![_bag_plan_matches]} { return 0 }
    set c [dict get $bag_plan changes]
    if {![dict exists $c bean_brand] && ![dict exists $c bean_type] && ![dict exists $c roast_date]} { return 0 }
    return [dict get $bag_plan skipped]
}

proc ::plugins::ShotHistoryEditor::_bag_warning_lines {max {last 0}} {
    variable L
    variable bag_plan
    set items {}
    set blocker [_pick [expr {$bag_plan ne ""}] [_dget $bag_plan blocker] [_bag_save_blocker]]
    if {$blocker ne ""} { lappend items "[translate {Save is off}]: $blocker" }
    foreach w [_bag_review_warnings [_bag_changes]] { lappend items $w }
    set left [_bag_left_behind]
    if {$left > 0} {
        lappend items "[_plural $left file files] [translate {cannot be changed (Skipped) and will stay in the old bag.}]"
    }
    set n [llength $items]
    # The last step before the write never says "more on the next step":
    # when the wrapped warnings do not fit, each gets one cut line, and a
    # list longer than max (only with Save off) ends with "+ N more".
    if {$last} {
        set out {}
        foreach item $items {
            lappend out {*}[split [_wrap_lines $item $L(font_caption) $L(content_w) 2] "\n"]
        }
        if {[llength $out] <= $max} { return $out }
        if {$n <= $max} {
            return [lmap item $items { _fit_line $item $L(font_caption) $L(content_w) }]
        }
        set out [lmap item [lrange $items 0 [expr {$max - 2}]] { _fit_line $item $L(font_caption) $L(content_w) }]
        lappend out "+ [expr {$n - $max + 1}] [translate {more warnings}]"
        return $out
    }
    set out {}
    for {set i 0} {$i < $n} {incr i} {
        set item [lindex $items $i]
        set wl [split [_wrap_lines $item $L(font_caption) $L(content_w) 2] "\n"]
        set after [expr {$n - $i - 1 > 0 ? 1 : 0}]
        if {[llength $out] + [llength $wl] + $after <= $max} {
            lappend out {*}$wl
            continue
        }
        if {[llength $out] + 1 + $after <= $max} {
            lappend out [_fit_line $item $L(font_caption) $L(content_w)]
            incr i
        }
        if {$n - $i > 0} {
            lappend out "+ [expr {$n - $i}] [_pick [expr {$blocker eq ""}] [translate {more on the next step}] [translate {more warnings}]]"
        }
        break
    }
    return $out
}

proc ::plugins::ShotHistoryEditor::_bag_save_is_running {} {
    variable bag_save_running
    if {$bag_save_running <= 0} { return 0 }
    set d [expr {[clock milliseconds] - $bag_save_running}]
    return [expr {$d >= 0 && $d < 600000}]
}

proc ::plugins::ShotHistoryEditor::bag_save_open {} {
    variable bag_plan
    variable bag_confirm_input
    variable bag_confirm_error
    variable bag_confirm_armed
    if {![_bag_flow_settled] || [_bag_save_is_running] || ![_bag_plan_matches]} { return }
    if {[dict get $bag_plan blocker] ne "" || [dict get $bag_plan to_change] == 0} { return }
    set bag_confirm_input ""
    set bag_confirm_error ""
    set bag_confirm_armed 1
    _paint_bag_confirm ShotHistoryEditor_bag_confirm
    open_page ShotHistoryEditor_bag_confirm
    _bag_flow_mark
}

proc ::plugins::ShotHistoryEditor::bag_confirm_cancel {} {
    variable bag_confirm_input
    variable bag_confirm_error
    variable bag_confirm_armed
    if {![_bag_flow_settled] || [_bag_save_is_running]} { return }
    set bag_confirm_input ""
    set bag_confirm_error ""
    set bag_confirm_armed 0
    bag_hide_keyboard
    _paint_bag_review ShotHistoryEditor_bag_review
    _return_to_page ShotHistoryEditor_bag_review
    _bag_flow_mark
}

proc ::plugins::ShotHistoryEditor::_paint_bag_confirm {page} {
    variable L
    variable bag_plan
    variable bag_cur
    variable bag_confirm_error
    variable bag_confirm_armed
    if {!$bag_confirm_armed || ![_bag_plan_matches] || [dict get $bag_plan to_change] == 0} {
        catch { dui item config $page subtitle -text [translate "Open a bag and its Review first."] }
        foreach t {bc_changes bc_warn bc_instr bc_files} { catch { dui item config $page $t -text "" } }
        # (a refusal from bag_confirm_submit stays readable)
        catch { dui item config $page bc_error -text $bag_confirm_error -fill $L(danger) }
        catch { dui item config $page bc_save -label [translate "Save"] }
        catch { dui item enable_or_disable 0 $page bc_save* -initial 1 }
        catch { dui item enable_or_disable 1 $page bc_cancel* -initial 1 }
        return
    }
    set n [dict get $bag_plan to_change]
    catch { dui item config $page subtitle -text [_fit_line [_bag_summary_line $bag_cur] $L(font_caption) $L(content_w)] }
    set parts {}
    foreach c [_bag_changes] {
        if {![dict get $c changed]} { continue }
        set v [_pick [expr {[dict get $c new] eq ""}] [translate empty] [dict get $c new]]
        lappend parts "[translate [dict get $c label]] [_u 0x2192] $v"
    }
    catch { dui item config $page bc_changes -text [_fit_line [join $parts "   "] $L(font_caption) $L(content_w)] }
    catch { dui item config $page bc_warn -text [join [_bag_warning_lines $L(bc_warn_lines) 1] "\n"] }
    catch { dui item config $page bc_instr -text \
        "[translate Type] $n [translate {(the number of files to change), then tap}] [translate Save] [_plural $n file files]." }
    catch { dui item config $page bc_error -text $bag_confirm_error -fill $L(danger) }
    set shots 0 ; set runs 0
    foreach f [dict get $bag_plan files] {
        if {[dict get $f status] ne "change"} { continue }
        if {[dict get $f cleaning]} { incr runs } else { incr shots }
    }
    set info "[_plural $n file files] [translate {will change}]: [_plural $shots shot shots], [_plural $runs {cleaning run} {cleaning runs}]."
    append info "\n[translate {Already up to date}]: [dict get $bag_plan unchanged]. [translate Skipped]: [dict get $bag_plan skipped]."
    append info "\n[translate {Every file is backed up and checked first, then rewritten and checked again; a failed check puts its backup back.}]"
    set np [_bag_next_for_plan]
    if {$np ne "" && [dict get $np status] eq "update" && [_dye_next_api]} {
        append info "\n[translate {history/*.shot and its history_v2 copies change, and through DYE your next-shot plan; SDB and Visualizer uploads keep the old values.}]"
    } else {
        append info "\n[translate {history/*.shot and its history_v2 copies change: SDB and Visualizer uploads keep the old values.}]"
    }
    set tw [expr {$L(content_w) - 2 * $L(card_pad_x)}]
    catch { dui item config $page bc_files -text [join [lmap l [split $info "\n"] { _wrap_lines $l $L(font_body) $tw 2 }] "\n"] }
    catch { dui item config $page bc_save -label "[translate Save] [_plural $n file files]" }
    catch { dui item enable_or_disable 1 $page bc_save* -initial 1 }
    catch { dui item enable_or_disable 1 $page bc_cancel* -initial 1 }
}

# Typed count, refusals, then the Save. Buttons go grey and a status line
# is painted first; the downstream refresh (Grind Advisor's SDB resync,
# which yields with `update`) runs while they are still grey, and the
# result page opens only after it.
proc ::plugins::ShotHistoryEditor::bag_confirm_submit {} {
    variable L
    variable bag_plan
    variable bag_cur
    variable bag_confirm_input
    variable bag_confirm_error
    variable bag_save_running
    variable bag_result_text
    variable bag_result_wrote
    variable bag_result_unseen
    set page ShotHistoryEditor_bag_confirm
    variable bag_confirm_armed
    if {![_bag_flow_settled] || [_bag_save_is_running] || $bag_plan eq "" || !$bag_confirm_armed} { return }
    if {![_bag_plan_matches]} {
        set bag_confirm_error [translate "The changes differ from the Review; open Review again. Nothing was written."]
        _paint_bag_confirm $page
        return
    }
    set n [dict get $bag_plan to_change]
    if {[string trim $bag_confirm_input] ne $n} {
        set bag_confirm_error "[translate {Type exactly}] \"$n\" [translate {to save. Nothing was written.}]"
        _paint_bag_confirm $page
        return
    }
    set busy [_machine_busy]
    if {$busy ne ""} {
        set bag_confirm_error "[translate {The DE1 is busy}] ($busy). [translate {Try again when it is idle. Nothing was written.}]"
        _paint_bag_confirm $page
        return
    }
    if {[_sdb_busy]} {
        set bag_confirm_error [translate "The shot database is syncing. Try again in a moment. Nothing was written."]
        _paint_bag_confirm $page
        return
    }
    set bag_save_running [clock milliseconds]
    bag_hide_keyboard
    catch { dui item enable_or_disable 0 $page bc_save* -initial 1 }
    catch { dui item enable_or_disable 0 $page bc_cancel* -initial 1 }
    catch { dui item config $page bc_error -fill $L(warn) \
        -text "[translate Saving] [_plural $n file files]... [translate {please wait.}]" }
    catch { update idletasks }
    set changed_identity [expr {[dict exists [dict get $bag_plan changes] bean_brand] ||
        [dict exists [dict get $bag_plan changes] bean_type] || [dict exists [dict get $bag_plan changes] roast_date]}]
    set next [dict create status none why "" old {} new {}]
    if {[catch { set r [perform_bag_save $bag_plan] } err]} {
        msg -ERROR "ShotHistoryEditor: bag save stopped by an error: $err"
        set r [dict create ok 0 message "[translate {Stopped by an error}]: $err" written {} unchanged {} \
            skipped {} failed {} restore_failed {} not_attempted {} backup_dir "" ts "" batch ""]
    }
    set note ""
    if {[llength [dict get $r written]]} {
        # v0.19.0 capability 8: the next-shot plan follows the bag, before
        # Grind Advisor and Lumen refresh (they read it).
        set next [_bag_next_apply [dict get $bag_plan key] [dict get $bag_plan changes] [_bag_value_sets $bag_cur] [dict get $r ts] [dict get $r batch]]
        catch { dui item config $page bc_error -text [translate "Updating Grind Advisor and the shot database..."] }
        catch { update idletasks }
        set note [_notify_downstream "the bag save"]
    }
    set bag_result_text [_bag_result_text $r $n $changed_identity $next $note]
    set bag_result_wrote [expr {[llength [dict get $r written]] > 0}]
    if {$bag_result_wrote} {
        # The bag may have a new name now: the editor starts over.
        set bag_cur {}
        set bag_plan {}
    }
    set bag_confirm_error ""
    set bag_confirm_input ""
    set bag_confirm_armed 0
    set bag_save_running 0
    catch { dui item enable_or_disable 1 $page bc_cancel* -initial 1 }
    catch { dui item enable_or_disable 1 $page bc_save* -initial 1 }
    _paint_bag_result ShotHistoryEditor_bag_result
    # The downstream refresh yields (SDB's populate runs update): if the app
    # moved to a machine page meanwhile, the result is not loaded over it --
    # the Bags status shows its first line instead.
    set busy [_machine_busy]
    if {![_page_is_current $page] || $busy ne ""} {
        set bag_result_unseen [lindex [split $bag_result_text "\n"] 0]
        if {$bag_result_wrote && [dict get $next status] ni {none applied}} {
            append bag_result_unseen " [translate {Your next shot still has the old details: load the bag again.}]"
        }
        msg -NOTICE "ShotHistoryEditor: bag save finished while the app was elsewhere ([_pick [expr {$busy ne {}}] $busy {another page}]); result kept for the Bags page"
        return
    }
    set bag_result_unseen ""
    open_page ShotHistoryEditor_bag_result
    _bag_flow_mark
}

# v0.24.0: the bag Save's history_v2 outcome, from the res v2 list (one
# {filename status reason backup log_ok} per written .shot): one count line,
# then any file that went wrong (a restore failure always, at most two others).
proc ::plugins::ShotHistoryEditor::_bag_v2_summary {v2} {
    if {[llength $v2] == 0} { return {} }
    set n [dict create ok 0 unchanged 0 absent 0 skipped 0 failed 0 restore_failed 0]
    set bad {} ; set rf {} ; set log_bad 0
    foreach e $v2 {
        lassign $e fn st why backup log_ok
        if {![dict exists $n $st]} { set st failed }
        dict incr n $st
        if {$st eq "restore_failed"} { lappend rf "   history_v2/$fn.json: [translate {could NOT be put back; the intact copy is}] $backup" }
        if {$st eq "failed"} { lappend bad "   history_v2/$fn.json: $why" }
        if {!$log_ok} { incr log_bad }
    }
    set parts [list "[dict get $n ok] [translate updated]"]
    if {[dict get $n unchanged]} { lappend parts "[dict get $n unchanged] [translate {already right}]" }
    if {[dict get $n absent]} { lappend parts "[dict get $n absent] [translate {without a copy}]" }
    if {[dict get $n skipped]} { lappend parts "[dict get $n skipped] [translate {left as they are}]" }
    set nf [expr {[dict get $n failed] + [dict get $n restore_failed]}]
    if {$nf} { lappend parts "$nf [translate {NOT updated}]" }
    set lines [list "history_v2: [join $parts {, }] ([translate {the .shot changes stand; see edit_log.txt, V2 lines}])."]
    lappend lines {*}$rf {*}[lrange $bad 0 1]
    if {$log_bad} { lappend lines "   [translate {edit_log.txt could not take}] $log_bad V2 [translate line(s)]." }
    return $lines
}

# next = the _bag_next_apply result ("" or 0: none).
proc ::plugins::ShotHistoryEditor::_bag_result_text {r n changed_identity next note} {
    set w [llength [dict get $r written]]
    set lines {}
    if {[dict get $r message] ne "" && $w == 0} {
        lappend lines [dict get $r message]
    } elseif {[llength [dict get $r restore_failed]] || [llength [dict get $r failed]] || [dict get $r message] ne ""} {
        lappend lines "[translate Stopped]: [translate saved] $w [translate of] [_plural $n file files]."
        if {[dict get $r message] ne ""} { lappend lines [dict get $r message] }
    } else {
        lappend lines "[translate Saved] [_plural $w file files]."
    }
    foreach {key label} {restore_failed {RESTORE FAILED} failed {Stopped at}} {
        foreach f [dict get $r $key] {
            lassign $f fn why
            lappend lines "[translate $label] $fn.shot: $why"
        }
    }
    set u [llength [dict get $r unchanged]]
    if {$u} { lappend lines "[translate {Already up to date}]: $u." }
    set sk [dict get $r skipped]
    if {[llength $sk]} {
        lappend lines "[translate Skipped]: [llength $sk]."
        foreach f [lrange $sk 0 2] { lassign $f fn why ; lappend lines "   $fn.shot: $why" }
        if {[llength $sk] > 3} { lappend lines "   + [expr {[llength $sk] - 3}] [translate {more, see edit_log.txt}]" }
    }
    set na [llength [dict get $r not_attempted]]
    if {$na} {
        lappend lines "[translate {Not attempted}]: [_plural $na file files] [translate {(unchanged on disk).}]"
    }
    if {$changed_identity && $w > 0 && $w + $u < $n} {
        lappend lines [translate "This bag is now split: open the old bag on the Bags page and save again to finish."]
    }
    if {[dict get $r backup_dir] ne "" && $w > 0} { lappend lines "[translate Backups]: [dict get $r backup_dir]" }
    if {$w > 0 && [llength $next] > 1 && [dict get $next status] ne "none"} {
        lappend lines {*}[_bag_next_lines $next]
    }
    if {$w > 0} {
        lappend lines {*}[_bag_v2_summary [_dget $r v2 {}]]
        if {[llength $next] > 1 && [dict get $next status] eq "applied"} {
            lappend lines [translate "history/*.shot and, through DYE, your next-shot plan changed; SDB is never written by this plugin; Visualizer uploads keep the old values."]
        } else {
            lappend lines [translate "history/*.shot changed: SDB is never written by this plugin; Visualizer uploads keep the old values."]
        }
        lappend lines [_pick [expr {$note ne ""}] "Grind Advisor: $note" \
            [translate "SDB picks the change up on its next resync (SDB settings: Resync database to history)."]]
    }
    return [join $lines "\n"]
}

proc ::plugins::ShotHistoryEditor::_paint_bag_result {page} {
    variable L
    variable bag_result_text
    set text [_pick [expr {$bag_result_text ne ""}] $bag_result_text [translate "No bag save has run yet."]]
    set out {}
    foreach l [split $text "\n"] { lappend out [_wrap_lines $l $L(font_body) $L(content_w) 2] }
    catch { dui item config $page br_text -text [join $out "\n"] }
}

# Done ends the flow. After a Save that wrote files: on the Bags page,
# freshly read (SDB plus the edit overlay) and painted before the unwind.
# After one that wrote nothing: back on Edit bag with the edits kept, so
# Review can be opened again. Taps queued while the Save ran are ignored
# (the flow's settle guard).
proc ::plugins::ShotHistoryEditor::bag_result_done {} {
    variable bag_result_wrote
    variable bag_cur
    if {![_bag_flow_settled]} { return }
    if {!$bag_result_wrote && $bag_cur ne ""} {
        _paint_bag_edit ShotHistoryEditor_bag_edit
        _return_to_page ShotHistoryEditor_bag_edit
    } else {
        refresh_bags_page ShotHistoryEditor_bags
        _return_to_page ShotHistoryEditor_bags
    }
    _bag_flow_mark
}

namespace eval ::dui::pages::ShotHistoryEditor_settings {
    # Pass 3.1 main page. Layout comes entirely from the ::plugins::ShotHistoryEditor::L
    # token array (see _init_layout) -- no hardcoded coordinates below.
    #
    # Part A fix: v0.3.0 stacked multiple full-size interactive dbuttons at
    # identical coordinates (select_btn/cancel_btn, bar_advanced/bar_delete,
    # bar_done/bar_clear, and three buttons per card row) and toggled which
    # one was visible with `dui item show/hide`. That overlapping-duplicate
    # pattern does not exist anywhere else in this plugin's proven-working
    # v0.2.0 code, where every button occupies a unique, non-overlapping
    # rectangle. Root cause: once more than one interactive widget shares a
    # bounding box, tap routing on this page/canvas system becomes ambiguous
    # (see causes #1/#2 in the brief) and none of the stacked widgets respond
    # reliably. Fix: every slot below now has exactly one dbutton, created
    # once, whose -command is a stable dispatcher (card_btn_click,
    # bar_left_click, bar_right_click, toggle_select_mode) that reads
    # select_mode at click time; only the button's caption is reconfigured
    # via `dui item config ... -label` (the same generic config path already
    # proven for -text throughout this file), so no two widgets ever occupy
    # the same rectangle and no command binding is ever swapped.
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page

        set lx $L(left_x)
        set rx $L(right_x)
        set cx [expr {($lx + $rx) / 2}]

        dui add dtext $page $cx $L(header_title_y) -tags page_title -text [translate "Shot History Editor"] \
            -font $L(font_title) -width $L(content_w) -fill $L(text_hi) -anchor center -justify center
        dui add dtext $page $cx $L(header_subtitle_y) -tags subtitle -text [translate "Edits and deletes are confirmed first. Delete moves shots to the trash."] \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor center -justify center
        # v0.18.1: the Shots | Bags switch, toolbar row left (was top-left).
        ::plugins::ShotHistoryEditor::_add_view_tabs $page shots

        # v0.13.1: theme toggle in the top-RIGHT corner, the exact box
        # MaintenanceTracker, GrindAdvisor and BeanScanner use (square
        # btn_h, y = 11 ref, right edge = right_x); it sat top-left before.
        set theme_y0 [expr {int(round(11 * $L(scale)))}]
        set theme_x1 [expr {$rx-$L(btn_h)}]
        dui add dbutton $page $theme_x1 $theme_y0 $rx [expr {$theme_y0+$L(btn_h)}] \
            -tags btn_theme -label [::plugins::ShotHistoryEditor::_theme_button_face] \
            -command ::plugins::ShotHistoryEditor::toggle_theme \
            -label_font [expr {$L(have_icons) ? $L(font_icon) : $L(font_button)}] \
            -style she_btn

        # Mode button (single button; see fix note above). v0.18.1 (owner
        # mockup): toolbar row right, in the card buttons' column, shorter
        # than a bar button (was in the header, left of the toggle).
        set sel_y0 [expr {$L(toolbar_mid_y) - $L(sel_btn_h) / 2}]
        dui add dbutton $page $L(sel_x0) $sel_y0 $L(sel_x1) [expr {$sel_y0+$L(sel_btn_h)}] \
            -tags mode_btn -label [translate "Select"] -command ::plugins::ShotHistoryEditor::toggle_select_mode \
            -label_font $L(font_button) -style she_btn

        # Toolbar status, centred between the switch and Select (v0.18.1;
        # the pager lives bottom-right since v0.13.1).
        dui add dtext $page $cx $L(toolbar_mid_y) -tags recent_status -text "" \
            -font $L(font_caption) -width $L(toolbar_status_w) \
            -fill $L(text_mut) -anchor center -justify center

        # Card list: exactly one background + 3 text lines + 1 action button per row.
        set btn_x2 [expr {$rx - $L(card_pad_x)}]
        set btn_x1 [expr {$btn_x2 - $L(card_btn_w)}]
        set text_x [expr {$lx + $L(card_pad_x)}]
        set text_w [expr {$L(card_w) - 2*$L(card_pad_x) - $L(card_btn_w) - $L(xl)}]

        for {set i 0} {$i < $::plugins::ShotHistoryEditor::card_page_size} {incr i} {
            set top [expr {$L(list_top) + $i*($L(card_h)+$L(card_gap))}]
            set bottom [expr {$top + $L(card_h)}]

            ::plugins::ShotHistoryEditor::rounded_rect $page $lx $top $rx $bottom $L(card_radius) \
                -fill $L(card_bg) -outline $L(card_outline) -width 2 -tags row${i}_bg

            dui add dtext $page $text_x [expr {$top+$L(card_line1_dy)}] -tags row${i}_line1 -text "" \
                -font $L(font_primary) -width $text_w -fill $L(text_hi) -anchor w -justify left
            dui add dtext $page $text_x [expr {$top+$L(card_line2_dy)}] -tags row${i}_line2 -text "" \
                -font $L(font_body) -width $text_w -fill $L(text_body) -anchor w -justify left
            dui add dtext $page $text_x [expr {$top+$L(card_line3_dy)}] -tags row${i}_line3 -text "" \
                -font $L(font_caption) -width $text_w -fill $L(text_mut) -anchor w -justify left

            # v0.16.0: CLEANING pill at the right end of line 1, an xl gap
            # short of the card button; hidden until the row is a cleaning run.
            set px2 [expr {$btn_x1 - $L(xl)}]
            set px1 [expr {$px2 - $L(clean_pill_w)}]
            set py1 [expr {$top + $L(card_line1_dy) - $L(clean_pill_h)/2}]
            ::plugins::ShotHistoryEditor::rounded_rect $page $px1 $py1 $px2 [expr {$py1+$L(clean_pill_h)}] \
                [expr {$L(clean_pill_h)/2}] -fill $L(clean_pill_bg) -outline $L(clean_pill_bg) -width 0 \
                -tags row${i}_clean_bg -initial_state hidden
            dui add dtext $page [expr {($px1+$px2)/2}] [expr {$top+$L(card_line1_dy)}] -tags row${i}_clean_txt \
                -text [translate "CLEANING"] -font $L(font_caption) -fill $L(clean_pill_text) -anchor center \
                -initial_state hidden

            set btn_y1 [expr {$top + int(($L(card_h)-$L(card_btn_h))/2)}]
            set btn_y2 [expr {$btn_y1 + $L(card_btn_h)}]
            dui add dbutton $page $btn_x1 $btn_y1 $btn_x2 $btn_y2 -tags row${i}_btn \
                -label [translate "[::plugins::ShotHistoryEditor::_u 0x270e] Edit"] -command "::plugins::ShotHistoryEditor::card_btn_click $i" \
                -label_font $L(font_button) -style she_btn
            # v0.15.0 (F12): in Select mode the whole card toggles. A
            # shape-less, label-less dbutton is the core's own invisible
            # tap rect (MaintenanceTracker's card-open zone): over the text
            # area, created after the lines so it sits above them, ending an
            # xl gap short of the card button -- the two never overlap. No
            # style, so no press fill. Does nothing outside Select mode.
            # The she_ prefix (review): dui's press flash repaints every
            # canvas item named like the pressed button's tag, across all
            # plugins, and on an invisible rect that paint would stick.
            dui add dbutton $page $lx $top [expr {$btn_x1 - $L(xl)}] $bottom -tags she_row${i}_tap \
                -command "::plugins::ShotHistoryEditor::card_tap_click $i"
        }

        # Bottom bar: one row. Single dispatcher per slot (see fix note).
        # v0.13.1: the two action slots sit side by side on the left and
        # the pager takes the bottom-right corner (owner: easier to reach).
        dui add dbutton $page $lx $L(bar_y0) [expr {$lx+$L(btn_w_std)}] $L(bar_y1) \
            -tags bar_left -label [translate "Done"] -command ::plugins::ShotHistoryEditor::bar_left_click \
            -label_font $L(font_button) -style she_btn
        set bar2_x1 [expr {$lx+$L(btn_w_std)+$L(sm)}]
        dui add dbutton $page $bar2_x1 $L(bar_y0) [expr {$bar2_x1+$L(btn_w_std)}] $L(bar_y1) \
            -tags bar_right -label [translate "Advanced"] -command ::plugins::ShotHistoryEditor::bar_right_click \
            -label_font $L(font_button) -style she_btn
        ::plugins::ShotHistoryEditor::_add_pager $page prev_page next_page \
            {::plugins::ShotHistoryEditor::scroll_cards -1} {::plugins::ShotHistoryEditor::scroll_cards 1}
    }

    proc show {page_to_hide page_to_show} {
        # Defensive rule: entering/returning to the main page always clears
        # any selection-mode guard state, so a stuck mode can never persist
        # across a page transition even if Cancel was somehow never tapped.
        set ::plugins::ShotHistoryEditor::select_mode 0
        ::plugins::ShotHistoryEditor::clear_selection_state
        # v0.5.2: capture the real caller so Done can navigate straight back
        # to it instead of trusting dui page close_dialog's "previous" (see
        # _navigate_done's note above -- that "previous" is wrong after a
        # flush/rinse/steam interruption).
        ::plugins::ShotHistoryEditor::_capture_return_page $page_to_hide
        ::plugins::ShotHistoryEditor::refresh_main_page $page_to_show
    }

    # v0.15.0 (F12, review): leaving the card page ends Select mode at once.
    # The show hook resets it too, but dui re-shows this page's items before
    # that hook runs (after idle), so a return from the delete review
    # flashed the red "Delete N", the tinted cards and a still-live Select
    # mode. dui runs this hook after idle with the page already hidden:
    # configs only, no show or hide, and enable_or_disable leaves hidden
    # items alone. The delete review works from its own snapshot of the
    # selection (open_delete_review), taken before the page was left.
    proc hide {page_to_hide page_to_show} {
        set ::plugins::ShotHistoryEditor::select_mode 0
        ::plugins::ShotHistoryEditor::clear_selection_state
        ::plugins::ShotHistoryEditor::_paint_all_card_sel $page_to_hide
        ::plugins::ShotHistoryEditor::_refresh_select_bar $page_to_hide
        catch { dui item config $page_to_hide mode_btn -label [translate "Select"] }
        catch { dui item config $page_to_hide bar_right -label [translate "Advanced"] }
        catch { dui item config $page_to_hide recent_status -text "" }
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_advanced {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        # v0.15.1 (F13): the shared sub-page header (40 px title).
        ::plugins::ShotHistoryEditor::_subpage_header $page "Advanced" \
            "Optional tools. Not required for normal use."
        dui add dtext $page $lx $L(toolbar_y0) -tags deleted_note -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(warn) -anchor nw -justify left

        # v0.15.2 (F18): grouped by purpose -- two section cards from
        # list_top (were six full-width buttons). Recover (left) brings
        # deleted shots back: Trash / Restore, and Reconcile (v0.9.0) with
        # its Unhide. Inspect (right) holds the read-only views. Same
        # buttons, tags and commands. Tidy moved to the Trash page, beside
        # Empty trash..., where it says how many folders it would remove.
        set col_w $L(sec_col_w)
        set pitch [expr {$L(btn_h) + $L(md)}]
        foreach {card x title rows} [list \
            sec_recover $lx "Recover" {
                trash_restore "Trash / Restore" ShotHistoryEditor_trash
                reconcile "Reconcile hidden shots" ShotHistoryEditor_reconcile
                migrate_preview "Move trash and logs..." ShotHistoryEditor_migrate_preview} \
            sec_inspect $L(sec_col2_x) "Inspect" {
                source_inspector "Source Inspector (Shot Detail)" ShotHistoryEditor_recent
                diagnostics "Diagnostics" ShotHistoryEditor_diagnostics
                help_guide "Help / Guide" ShotHistoryEditor_help}] {
            set n [expr {[llength $rows] / 3}]
            set h [expr {2 * $L(sec_pad) + $L(sec_title_h) + $L(md) + $n * $pitch - $L(md)}]
            set y [::plugins::ShotHistoryEditor::_sec_card $page $card $x $L(list_top) $col_w $h $title]
            foreach {tag label target} $rows {
                dui add dbutton $page [expr {$x + $L(sec_pad)}] $y \
                    [expr {$x + $col_w - $L(sec_pad)}] [expr {$y + $L(btn_h)}] -tags $tag \
                    -label [translate $label] -command [list ::plugins::ShotHistoryEditor::open_page $target] \
                    -label_font $L(font_button) -style she_btn
                incr y $pitch
            }
        }

        # v0.4.1 bugfix: was open_page (open_dialog on an ancestor already in
        # the stack, same fault class as the delete-flow exits -- see
        # _return_to_page). Advanced is only ever reached from the main
        # settings page, so this call always targets the immediate parent.
        # v0.15.1 (F13): drawn by the shared _add_back.
        ::plugins::ShotHistoryEditor::_add_back $page \
            {::plugins::ShotHistoryEditor::_return_to_page ShotHistoryEditor_settings}
    }

    proc show {page_to_hide page_to_show} {
        # v0.13.0: the note is built by refresh_advanced_page. v0.15.2: the
        # Tidy result moved to the Trash page with the button.
        ::plugins::ShotHistoryEditor::refresh_advanced_page $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_delete_review {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Delete -- Step 1: Review" \
            "Nothing has moved yet. Check the list, then tap Continue." danger
        dui add dtext $page $lx $L(toolbar_y0) -tags review_count_text -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left
        dui add dtext $page $lx [expr {$L(toolbar_y0)+$L(lg)}] -tags review_intro \
            -text [translate "These shots will be moved to the plugin trash folder. Nothing is permanently deleted."] \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left

        dui add dtext $page $lx [expr {$L(toolbar_y0)+2*$L(lg)}] -tags review_page_status -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left
        dui add dtext $page $lx $L(list_top) -tags review_text -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left

        set right_btn_x1 [expr {$rx-$L(btn_w_std)}]
        set left_btn_x1 [expr {$right_btn_x1-$L(sm)-$L(btn_w_std)}]
        # v0.6.2: Cancel to the far left, with the delete flow's forward
        # button left where it is. Same reasoning as the edit flow: the way
        # OUT is always the bottom-left corner, and the destructive button is
        # never under the thumb that keeps tapping there.
        dui add dbutton $page $lx $L(bar_y0) [expr {$lx+$L(btn_w_std)}] $L(bar_y1) -tags cancel \
            -label [translate "Cancel"] -command ::plugins::ShotHistoryEditor::cancel_delete_review \
            -label_font $L(font_button) -style she_btn
        dui add dbutton $page $right_btn_x1 $L(bar_y0) $rx $L(bar_y1) -tags continue_btn \
            -label [translate "Continue"] -command ::plugins::ShotHistoryEditor::open_delete_confirm \
            -label_font $L(font_button) -style she_btn
    }

    proc show {page_to_hide page_to_show} {
        ::plugins::ShotHistoryEditor::refresh_delete_review_page $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_delete_confirm {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Delete -- Step 2: Confirm" \
            "The shots move to the plugin trash; Trash / Restore can bring them back." danger

        # Typed confirmation input stays in the top half of the screen (Android
        # keyboard covers the bottom).
        dui add dtext $page $lx $L(toolbar_y0) -tags confirm_instructions -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left
        dui add entry $page $lx [expr {$L(toolbar_y0)+3*$L(lg)}] -tags confirm_entry \
            -textvariable ::plugins::ShotHistoryEditor::confirm_input \
            -width 20 -font $L(font_primary) -borderwidth 1 -bg $L(entry_danger_bg) -foreground $L(danger) -relief flat \
            -label [translate "Type the number here"] -label_pos [list $lx [expr {$L(toolbar_y0)+2*$L(lg)}]] \
            -label_font $L(font_body) -label_width $L(label_col_w) -label_fill $L(text_body)
        dui add dtext $page $lx [expr {$L(toolbar_y0)+5*$L(lg)}] -tags confirm_error_text -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(danger) -anchor nw -justify left

        set right_btn_x1 [expr {$rx-$L(btn_w_std)}]
        set left_btn_x1 [expr {$right_btn_x1-$L(sm)-$L(btn_w_std)}]
        # v0.6.2: Cancel to the far left; Delete stays on the right.
        dui add dbutton $page $lx $L(bar_y0) [expr {$lx+$L(btn_w_std)}] $L(bar_y1) -tags cancel \
            -label [translate "Cancel"] -command ::plugins::ShotHistoryEditor::cancel_delete_confirm \
            -label_font $L(font_button) -style she_btn
        dui add dbutton $page $right_btn_x1 $L(bar_y0) $rx $L(bar_y1) -tags confirm_delete \
            -label [translate "Confirm Delete"] -label_fill $L(danger) \
            -command ::plugins::ShotHistoryEditor::confirm_delete_submit \
            -label_font $L(font_button) -style she_btn
    }

    proc show {page_to_hide page_to_show} {
        ::plugins::ShotHistoryEditor::refresh_delete_confirm_page $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_delete_result {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Delete Result" \
            "The outcome of the delete. Moved shots can be restored from Trash / Restore."
        dui add dtext $page $lx $L(list_top) -tags result_text -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left

        # v0.6.2: Done at the FAR LEFT, like every other page in this plugin
        # now and like the card list it returns to.
        dui add dbutton $page $lx $L(bar_y0) [expr {$lx+$L(btn_w_std)}] $L(bar_y1) -tags page_done \
            -label [translate "Done"] -command ::plugins::ShotHistoryEditor::close_delete_result \
            -label_font $L(font_button) -style she_btn
    }

    proc show {page_to_hide page_to_show} {
        ::plugins::ShotHistoryEditor::refresh_delete_result_page $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_edit_confirm {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Save -- Confirm Change" \
            "The file is backed up first, and only this one field changes." danger

        dui add dtext $page $lx $L(toolbar_y0) -tags confirm_shot_text -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left
        dui add dtext $page $lx [expr {$L(toolbar_y0)+$L(lg)}] -tags confirm_file_text -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left
        dui add dtext $page $lx [expr {$L(toolbar_y0)+2*$L(lg)}] -tags confirm_field_text -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left
        dui add dtext $page $lx [expr {$L(toolbar_y0)+3*$L(lg)}] -tags confirm_before_text -text "" \
            -font $L(font_primary) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left
        # v0.23.0: an xs gap below each primary line (the 22 px lines are one
        # lg tall, so Before, After and the warning touched; the known polish
        # item, found by this pass's page check).
        dui add dtext $page $lx [expr {$L(toolbar_y0)+4*$L(lg)+$L(xs)}] -tags confirm_after_text -text "" \
            -font $L(font_primary) -width $L(content_w) -fill $L(danger) -anchor nw -justify left
        dui add dtext $page $lx [expr {$L(toolbar_y0)+5*$L(lg)+2*$L(xs)}] -tags confirm_warning_text -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(warn) -anchor nw -justify left
        # v0.23.0: what happens to the shot's history_v2 copy (nothing yet).
        dui add dtext $page $lx [expr {$L(toolbar_y0)+7*$L(lg)+2*$L(xs)}] -tags confirm_v2_text -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left

        # v0.6.2: Cancel takes the far-left slot -- it is this page's way out,
        # the same role Done plays everywhere else, so backing out of the
        # whole flow is the same corner every time.
        #
        # Save Change deliberately does NOT move. It is the destructive
        # button, and the one place it must not be is under the thumb that is
        # tapping bottom-left repeatedly to leave.
        dui add dbutton $page $lx $L(bar_y0) [expr {$lx+$L(btn_w_std)}] $L(bar_y1) -tags cancel \
            -label [translate "Cancel"] -command ::plugins::ShotHistoryEditor::cancel_edit_confirm \
            -label_font $L(font_button) -style she_btn
        dui add dbutton $page [expr {$rx-$L(btn_w_std)}] $L(bar_y0) $rx $L(bar_y1) -tags save_change \
            -label [translate "Save Change"] -label_fill $L(danger) \
            -command ::plugins::ShotHistoryEditor::confirm_save_submit \
            -label_font $L(font_button) -style she_btn
    }

    proc show {page_to_hide page_to_show} {
        ::plugins::ShotHistoryEditor::refresh_edit_confirm_page $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_edit_result {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Save Result" \
            "The outcome of the save, and where the backup was written."
        dui add dtext $page $lx $L(list_top) -tags edit_result_text -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left

        # v0.6.2: Done at the FAR LEFT. This is the page you land on after
        # saving, so it is the one whose Done gets tapped straight after
        # another one.
        dui add dbutton $page $lx $L(bar_y0) [expr {$lx+$L(btn_w_std)}] $L(bar_y1) -tags page_done \
            -label [translate "Done"] -command ::plugins::ShotHistoryEditor::close_edit_result \
            -label_font $L(font_button) -style she_btn
    }

    proc show {page_to_hide page_to_show} {
        ::plugins::ShotHistoryEditor::refresh_edit_result_page $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_trash {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Trash / Restore" \
            "Deleted shots wait here in batches; Restore puts a batch back."
        dui add dtext $page $lx $L(toolbar_y0) -tags trash_status -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left

        # v0.14.0 (F6): the house card list -- the main page's geometry and
        # tokens exactly (list_top, card_h, card_gap, three text lines, one
        # card action button) -- five batches per page, each card naming its
        # shot (_trash_card_lines). Restore stays per batch. The old column
        # header line is gone: the cards say what they are.
        set btn_x2 [expr {$rx - $L(card_pad_x)}]
        set btn_x1 [expr {$btn_x2 - $L(card_btn_w)}]
        set text_x [expr {$lx + $L(card_pad_x)}]
        set text_w [expr {$L(card_w) - 2*$L(card_pad_x) - $L(card_btn_w) - $L(xl)}]
        # Every card part starts HIDDEN (-initial_state hidden, the core's
        # own pattern): page load re-shows items that are not tagged hidden
        # before show{} runs, so empty slots flashed as blank cards with a
        # Restore button (review). refresh_trash_page shows the used ones.
        for {set i 0} {$i < $::plugins::ShotHistoryEditor::trash_page_size} {incr i} {
            set top [expr {$L(list_top) + $i*($L(card_h)+$L(card_gap))}]
            set bottom [expr {$top + $L(card_h)}]
            ::plugins::ShotHistoryEditor::rounded_rect $page $lx $top $rx $bottom $L(card_radius) \
                -fill $L(card_bg) -outline $L(card_outline) -width 2 -tags row${i}_bg \
                -initial_state hidden
            dui add dtext $page $text_x [expr {$top+$L(card_line1_dy)}] -tags row${i}_line1 -text "" \
                -font $L(font_primary) -width $text_w -fill $L(text_hi) -anchor w -justify left \
                -initial_state hidden
            dui add dtext $page $text_x [expr {$top+$L(card_line2_dy)}] -tags row${i}_line2 -text "" \
                -font $L(font_body) -width $text_w -fill $L(text_body) -anchor w -justify left \
                -initial_state hidden
            dui add dtext $page $text_x [expr {$top+$L(card_line3_dy)}] -tags row${i}_line3 -text "" \
                -font $L(font_caption) -width $text_w -fill $L(text_mut) -anchor w -justify left \
                -initial_state hidden
            set btn_y1 [expr {$top + int(($L(card_h)-$L(card_btn_h))/2)}]
            dui add dbutton $page $btn_x1 $btn_y1 $btn_x2 [expr {$btn_y1 + $L(card_btn_h)}] \
                -tags row${i}_restore -label [translate "Restore"] \
                -command "::plugins::ShotHistoryEditor::restore_row $i" -label_font $L(font_button) -style she_btn \
                -initial_state hidden
        }

        # v0.15.1 (F13): one way out -- Back, bottom-left (Done ran the same
        # return and is gone). Empty trash... (opens the read-only PREVIEW
        # page, v0.11.0) takes the next slot; the standard pager holds the
        # bottom-right corner. Trash is only ever reached from Advanced.
        set bw $L(btn_w_std)
        set x [::plugins::ShotHistoryEditor::_add_back $page \
            {::plugins::ShotHistoryEditor::_return_to_page ShotHistoryEditor_advanced}]
        dui add dbutton $page $x $L(bar_y0) [expr {$x+$bw}] $L(bar_y1) -tags empty_preview \
            -label [translate "Empty trash..."] -command {::plugins::ShotHistoryEditor::open_page ShotHistoryEditor_empty_preview} \
            -label_font $L(font_button) -style she_btn
        # v0.15.2 (F18): Tidy moved here from Advanced. It removes only EMPTY
        # folders directly under the plugin trash (v0.13.0, unchanged) and
        # now says how many -- "Tidy N empty folders", greyed out at 0
        # (_refresh_tidy_btn). Wide: its label needs more than btn_w_std.
        incr x [expr {$bw+$L(sm)}]
        dui add dbutton $page $x $L(bar_y0) [expr {$x+$L(btn_w_xwide)}] $L(bar_y1) -tags tidy \
            -label [translate "Tidy empty folders"] -command ::plugins::ShotHistoryEditor::tidy_trash_folders \
            -label_font $L(font_button) -style she_btn
        ::plugins::ShotHistoryEditor::_add_pager $page trash_prev_page trash_next_page \
            {::plugins::ShotHistoryEditor::scroll_trash -1} {::plugins::ShotHistoryEditor::scroll_trash 1}
    }

    proc show {page_to_hide page_to_show} {
        set ::plugins::ShotHistoryEditor::trash_offset 0
        # v0.15.2: a Tidy result shows only until the page is next shown.
        set ::plugins::ShotHistoryEditor::tidy_note ""
        ::plugins::ShotHistoryEditor::refresh_trash_page $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_recent {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]
        set open_w $L(btn_w_std)
        set text_w [expr {$L(content_w)-$open_w-$L(lg)}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Source Inspector" \
            "The newest shots in SDB. Open one to see its source files."
        dui add dtext $page $lx $L(toolbar_y0) -tags recent_status -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left
        set header_y [expr {$L(toolbar_y1)+$L(sm)}]
        dui add dtext $page $lx $header_y -tags header \
            -text "Date/time | Filename | Grind | Dose | Yield | Bean | Shot time" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left

        # 8 rows must fit exactly between the header line and the bottom bar,
        # so row_h is derived from the actual available space (not a fixed
        # fraction of card_h) -- a fixed 0.68*card_h row height overflowed
        # past bar_y0 on an 8-row list at the reference resolution.
        # v0.8.6: the row count IS max_recent (7), so the list, the refresh
        # loop and the query always agree; with 7 rows the band is ~143
        # virtual and the button reaches the full btn_h (60 physical px).
        set n_rows $::plugins::ShotHistoryEditor::max_recent
        set list_start [expr {$header_y+$L(caption_h)+$L(md)}]
        set list_end [expr {$L(bar_y0)-$L(md)}]
        set row_h [expr {double($list_end-$list_start)/$n_rows}]
        # v0.8.5: centred bands, same as the Trash page.
        set row_btn_h [expr {min($L(btn_h), $row_h - $L(sm))}]
        for {set i 0} {$i < $n_rows} {incr i} {
            set band_top [expr {$list_start + $i*$row_h}]
            set ty [expr {$band_top + ($row_h - $L(caption_h))/2.0}]
            set by0 [expr {$band_top + ($row_h - $row_btn_h)/2.0}]
            dui add dtext $page $lx $ty -tags row${i}_text -text "" \
                -font $L(font_caption) -width $text_w -fill $L(text_body) -anchor nw -justify left
            dui add dbutton $page [expr {$rx-$open_w}] $by0 $rx [expr {$by0+$row_btn_h}] \
                -tags row${i}_open -label [translate "Open"] \
                -command "::plugins::ShotHistoryEditor::select_recent_row $i" -label_font $L(font_button) -style she_btn
        }

        # v0.15.1 (F13): one way out -- Back, bottom-left (Done ran the same
        # return and is gone). Only ever reached from Advanced.
        ::plugins::ShotHistoryEditor::_add_back $page \
            {::plugins::ShotHistoryEditor::_return_to_page ShotHistoryEditor_advanced}
    }

    proc show {page_to_hide page_to_show} {
        ::plugins::ShotHistoryEditor::refresh_recent_page $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_detail {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Shot Detail" \
            "This shot's saved details. Edit Metadata Preview changes one field."
        dui add dtext $page $lx $L(toolbar_y0) -tags detail_page_status -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left
        dui add dtext $page $lx $L(list_top) -tags detail_text -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left

        # v0.15.1 (F13): one way out -- Back, bottom-left (Done ran the same
        # return and is gone); Edit Metadata Preview takes the next slot
        # (wide: 300 ref, its label needs more than btn_w_std) and the
        # standard pager holds the bottom-right corner. Shot Detail is only
        # ever reached from Source Inspector.
        set x [::plugins::ShotHistoryEditor::_add_back $page \
            {::plugins::ShotHistoryEditor::_return_to_page ShotHistoryEditor_recent}]
        dui add dbutton $page $x $L(bar_y0) [expr {$x+$L(btn_w_xwide)}] $L(bar_y1) -tags edit_preview \
            -label [translate "Edit Metadata Preview"] -command {::plugins::ShotHistoryEditor::open_edit_preview ShotHistoryEditor_detail} \
            -label_font $L(font_button) -style she_btn
        ::plugins::ShotHistoryEditor::_add_pager $page prev_page next_page \
            {::plugins::ShotHistoryEditor::scroll_page detail -1 ShotHistoryEditor_detail} \
            {::plugins::ShotHistoryEditor::scroll_page detail 1 ShotHistoryEditor_detail}
    }

    proc show {page_to_hide page_to_show} {
        set ::plugins::ShotHistoryEditor::detail_page_index 0
        ::plugins::ShotHistoryEditor::scroll_page detail 0 $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_edit_preview {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]
        set vx $L(value_x)

        ::plugins::ShotHistoryEditor::_subpage_header $page "Edit Preview" \
            "Pick a field and a new value. Nothing is saved until you confirm."
        dui add dtext $page $lx $L(toolbar_y0) -tags selected_shot -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left
        dui add dtext $page $lx [expr {$L(toolbar_y0)+$L(lg)}] -tags editable_source -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left

        set row1_y $L(list_top)
        dui add dtext $page $lx $row1_y -tags fs_label -text [translate "Field selector"] \
            -font $L(font_body) -width $L(label_col_w) -fill $L(text_body) -anchor nw -justify left
        dui add dtext $page $vx $row1_y -tags field_value -text "" \
            -font $L(font_body) -width [expr {$rx-$L(btn_w_wide)-$L(lg)-$vx}] -fill $L(value_blue) -anchor nw -justify left
        dui add dbutton $page [expr {$rx-$L(btn_w_wide)}] [expr {$row1_y-$L(sm)}] $rx [expr {$row1_y-$L(sm)+$L(btn_h)}] \
            -tags next_field -label [translate "Next Field"] \
            -command ::plugins::ShotHistoryEditor::cycle_edit_field -label_font $L(font_button) -style she_btn

        set row2_y [expr {$row1_y+$L(btn_h)+$L(lg)}]
        dui add dtext $page $lx $row2_y -tags cv_label -text [translate "Current value"] \
            -font $L(font_body) -width $L(label_col_w) -fill $L(text_body) -anchor nw -justify left
        dui add dtext $page $vx $row2_y -tags current_value -text "" \
            -font $L(font_body) -width [expr {$rx-$vx}] -fill $L(text_body) -anchor nw -justify left

        set row3_y [expr {$row2_y+$L(xxl)}]
        dui add entry $page $lx [expr {$row3_y+$L(xl)}] -tags new_value \
            -textvariable ::plugins::ShotHistoryEditor::edit_new_value \
            -width 42 -font $L(font_body) -borderwidth 1 -bg $L(entry_bg) -foreground $L(value_blue) -relief flat \
            -label [translate "New value"] -label_pos [list $lx $row3_y] \
            -label_font $L(font_body) -label_width $L(label_col_w) -label_fill $L(text_body)

        dui add dbutton $page [expr {$rx-$L(btn_w_wide)}] $row3_y $rx [expr {$row3_y+$L(btn_h)}] \
            -tags preview_change -label [translate "Preview Change"] \
            -command ::plugins::ShotHistoryEditor::preview_change -label_font $L(font_button) -style she_btn

        # v0.5.0: the one new control on this otherwise-unchanged page. Goes
        # to the Before/After Confirm page (Step 2 of the real save flow);
        # it does not write anything itself.
        set row4_y [expr {$row3_y+$L(btn_h)+$L(md)}]
        dui add dbutton $page [expr {$rx-$L(btn_w_wide)}] $row4_y $rx [expr {$row4_y+$L(btn_h)}] \
            -tags save_change -label [translate "Save Change"] -label_fill $L(danger) \
            -command ::plugins::ShotHistoryEditor::open_edit_confirm -label_font $L(font_button) -style she_btn

        set status_y [expr {$row4_y+$L(btn_h)+$L(xxl)}]
        dui add dtext $page $lx $status_y -tags preview_status -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(warn) -anchor nw -justify left
        # v0.23.0: two caption rows below the status (it is two rows with a
        # warning, and touched the text at xl), then the up-to-9-row preview.
        dui add dtext $page $lx [expr {$status_y+2*$L(caption_h)+$L(sm)}] -tags preview_text -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left

        # v0.15.1 (F13): one way out -- Back, bottom-left, the same corner
        # as the card list's own Done (v0.6.1 owner request). Done ran the
        # identical command (back_from_edit_preview, to the real caller in
        # edit_return_page) and is gone.
        ::plugins::ShotHistoryEditor::_add_back $page ::plugins::ShotHistoryEditor::back_from_edit_preview
    }

    proc show {page_to_hide page_to_show} {
        ::plugins::ShotHistoryEditor::refresh_edit_preview_page $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_diagnostics {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Diagnostics" \
            "What the plugin found: the SDB database, its tables, your shot folders."
        dui add dtext $page $lx $L(toolbar_y0) -tags diagnostics_page_status -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left
        dui add dtext $page $lx $L(list_top) -tags diagnostics_text -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left

        # v0.15.1 (F13): one way out -- Back, bottom-left (Done ran the same
        # return and is gone); the standard pager, bottom-right. Only ever
        # reached from Advanced.
        ::plugins::ShotHistoryEditor::_add_back $page \
            {::plugins::ShotHistoryEditor::_return_to_page ShotHistoryEditor_advanced}
        ::plugins::ShotHistoryEditor::_add_pager $page prev_page next_page \
            {::plugins::ShotHistoryEditor::scroll_page diagnostics -1 ShotHistoryEditor_diagnostics} \
            {::plugins::ShotHistoryEditor::scroll_page diagnostics 1 ShotHistoryEditor_diagnostics}
    }

    proc show {page_to_hide page_to_show} {
        set ::plugins::ShotHistoryEditor::diagnostics_page_index 0
        ::plugins::ShotHistoryEditor::scroll_page diagnostics 0 $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_help {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Help / Guide" \
            "How browsing, editing, deleting and restoring work."

        dui add dtext $page $lx $L(toolbar_y0) -tags help_page_status -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left
        dui add dtext $page $lx $L(list_top) -tags help_text -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left

        # v0.15.1 (F13): one way out -- Back, bottom-left (Done ran the same
        # return and is gone); the standard pager, bottom-right. Only ever
        # reached from Advanced.
        ::plugins::ShotHistoryEditor::_add_back $page \
            {::plugins::ShotHistoryEditor::_return_to_page ShotHistoryEditor_advanced}
        ::plugins::ShotHistoryEditor::_add_pager $page prev_page next_page \
            {::plugins::ShotHistoryEditor::scroll_page help -1 ShotHistoryEditor_help} \
            {::plugins::ShotHistoryEditor::scroll_page help 1 ShotHistoryEditor_help}
    }

    proc show {page_to_hide page_to_show} {
        set ::plugins::ShotHistoryEditor::help_page_index 0
        ::plugins::ShotHistoryEditor::scroll_page help 0 $page_to_show
    }
}

# v0.9.0: reconciliation view. v0.10.0: a row list with an Unhide button per
# row and the Trash-style pager (was paged text). Rows are centred bands of
# three caption lines; layout mirrors the Trash page.
namespace eval ::dui::pages::ShotHistoryEditor_reconcile {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]
        set unhide_w $L(btn_w_std)
        set text_w [expr {$L(content_w)-$unhide_w-$L(lg)}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Reconcile hidden shots" \
            "Trashed shots whose files are back in history/. Unhide lists them again."
        dui add dtext $page $lx $L(toolbar_y0) -tags reconcile_status -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left

        # Two status lines can sit above this header: toolbar_y0 + 2 caption
        # lines + sm.
        set header_y [expr {$L(toolbar_y0)+2*$L(caption_h)+$L(sm)}]
        dui add dtext $page $lx $header_y -tags header \
            -text "Shot  |  deleted when, batch  |  on disk vs trash copy  |  SDB" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left

        set n_rows $::plugins::ShotHistoryEditor::reconcile_page_size
        set list_start [expr {$header_y+$L(caption_h)+$L(md)}]
        set list_end [expr {$L(bar_y0)-$L(md)}]
        set row_h [expr {double($list_end-$list_start)/$n_rows}]
        set row_btn_h [expr {min($L(btn_h), $row_h - $L(sm))}]
        for {set i 0} {$i < $n_rows} {incr i} {
            set band_top [expr {$list_start + $i*$row_h}]
            set ty [expr {$band_top + ($row_h - 3*$L(caption_h))/2.0}]
            set by0 [expr {$band_top + ($row_h - $row_btn_h)/2.0}]
            dui add dtext $page $lx $ty -tags row${i}_text -text "" \
                -font $L(font_caption) -width $text_w -fill $L(text_body) -anchor nw -justify left
            dui add dbutton $page [expr {$rx-$unhide_w}] $by0 $rx [expr {$by0+$row_btn_h}] \
                -tags row${i}_unhide -label [translate "Unhide"] \
                -command "::plugins::ShotHistoryEditor::unhide_row $i" -label_font $L(font_button) -style she_btn
        }

        # v0.15.1 (F13): one way out -- Back, bottom-left (Done ran the same
        # return and is gone). Only ever reached from Advanced.
        ::plugins::ShotHistoryEditor::_add_back $page \
            {::plugins::ShotHistoryEditor::_return_to_page ShotHistoryEditor_advanced}
        # v0.13.1: the standard pager, bottom-right.
        ::plugins::ShotHistoryEditor::_add_pager $page reconcile_prev_page reconcile_next_page \
            {::plugins::ShotHistoryEditor::scroll_reconcile -1} {::plugins::ShotHistoryEditor::scroll_reconcile 1}
    }

    proc show {page_to_hide page_to_show} {
        set ::plugins::ShotHistoryEditor::reconcile_offset 0
        set ::plugins::ShotHistoryEditor::reconcile_note ""
        ::plugins::ShotHistoryEditor::refresh_reconcile_page $page_to_show
    }
}

# v0.11.0: Empty trash PREVIEW. Diagnostics skeleton (paged text, Back /
# Prev / Next); content from empty_trash_preview_text; reached from the Trash
# page and returns there. Nothing on this page deletes anything.
namespace eval ::dui::pages::ShotHistoryEditor_empty_preview {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Empty trash - preview" \
            "What Empty trash would remove for good. Nothing is removed on this page."
        dui add dtext $page $lx $L(toolbar_y0) -tags empty_preview_page_status -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left
        dui add dtext $page $lx $L(list_top) -tags empty_preview_text -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left

        # v0.15.1 (F13): one way out -- Back, bottom-left (Done ran the same
        # return and is gone). Only ever reached from the Trash page.
        set bw $L(btn_w_std)
        ::plugins::ShotHistoryEditor::_add_back $page \
            {::plugins::ShotHistoryEditor::_return_to_page ShotHistoryEditor_trash}
        # v0.12.0: the real action, danger label; hidden while the trash is
        # empty. Opens the typed confirmation; deletes nothing itself.
        # v0.15.1 (review): in the RIGHT group, an sm gap left of Prev -- never
        # in the slot beside Back, where a thumb tapping its way out lands
        # (with Done gone that slot was Back's old place).
        set prev_x0 [expr {$L(right_x) - 2*$bw - $L(sm)}]
        set x [expr {$prev_x0 - $L(sm) - $bw}]
        dui add dbutton $page $x $L(bar_y0) [expr {$x+$bw}] $L(bar_y1) -tags empty_now \
            -label [translate "Empty trash"] -label_fill $L(danger) \
            -command ::plugins::ShotHistoryEditor::open_purge_confirm \
            -label_font $L(font_button) -style she_btn
        ::plugins::ShotHistoryEditor::_add_pager $page prev_page next_page \
            {::plugins::ShotHistoryEditor::scroll_page empty_preview -1 ShotHistoryEditor_empty_preview} \
            {::plugins::ShotHistoryEditor::scroll_page empty_preview 1 ShotHistoryEditor_empty_preview}
    }

    proc show {page_to_hide page_to_show} {
        set ::plugins::ShotHistoryEditor::empty_preview_page_index 0
        ::plugins::ShotHistoryEditor::scroll_page empty_preview 0 $page_to_show
        if {[llength [::plugins::ShotHistoryEditor::_trash_batches]] > 0} {
            catch { dui item show $page_to_show empty_now* -initial 1 }
        } else {
            catch { dui item hide $page_to_show empty_now* -initial 1 }
        }
    }
}

# v0.21.0: the history_trash move page (Empty trash preview's shape: paged
# text, Back, pager). v0.22.0: plus Move now... (Finish move... after a
# stop), which only opens the typed confirmation; nothing on this page
# writes. Greyed out whenever the plan refuses.
namespace eval ::dui::pages::ShotHistoryEditor_migrate_preview {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x)

        ::plugins::ShotHistoryEditor::_subpage_header $page "Move trash and logs" \
            "Moves the plugin's trash, backups and logs to the app's data folder. Nothing moves on this page."
        dui add dtext $page $lx $L(toolbar_y0) -tags migrate_preview_page_status -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left
        dui add dtext $page $lx $L(list_top) -tags migrate_preview_text -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left
        ::plugins::ShotHistoryEditor::_add_back $page \
            {::plugins::ShotHistoryEditor::_return_to_page ShotHistoryEditor_advanced}
        # The right group, an sm gap left of Prev (never beside Back).
        set bw $L(btn_w_std)
        set x [expr {$L(right_x) - 3*$bw - 2*$L(sm)}]
        dui add dbutton $page $x $L(bar_y0) [expr {$x+$bw}] $L(bar_y1) -tags migrate_now \
            -label [translate "Move now..."] -command ::plugins::ShotHistoryEditor::open_migrate_confirm \
            -label_font $L(font_button) -style she_btn
        ::plugins::ShotHistoryEditor::_add_pager $page prev_page next_page \
            {::plugins::ShotHistoryEditor::scroll_page migrate_preview -1 ShotHistoryEditor_migrate_preview} \
            {::plugins::ShotHistoryEditor::scroll_page migrate_preview 1 ShotHistoryEditor_migrate_preview}
    }

    proc show {page_to_hide page_to_show} {
        set ::plugins::ShotHistoryEditor::migrate_preview_page_index 0
        ::plugins::ShotHistoryEditor::scroll_page migrate_preview 0 $page_to_show
        ::plugins::ShotHistoryEditor::_refresh_migrate_now $page_to_show
    }
}

# v0.22.0: the move's typed confirmation (the Empty trash confirmation's
# shape; the entry stays in the top half for the Android keyboard). Its show
# builds the plan afresh, so what it lists is what the count is typed for.
namespace eval ::dui::pages::ShotHistoryEditor_migrate_confirm {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x)

        ::plugins::ShotHistoryEditor::_subpage_header $page "Move trash and logs -- Confirm" \
            "One rename per item into history_trash/. Nothing is deleted; only the manifest is copied."
        dui add dtext $page $lx $L(toolbar_y0) -tags migrate_instructions -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left
        dui add entry $page $lx [expr {$L(toolbar_y0)+3*$L(lg)}] -tags migrate_entry \
            -textvariable ::plugins::ShotHistoryEditor::migrate_input \
            -width 20 -font $L(font_primary) -borderwidth 1 -bg $L(entry_bg) -foreground $L(value_blue) -relief flat \
            -label [translate "Type the number here"] -label_pos [list $lx [expr {$L(toolbar_y0)+2*$L(lg)}]] \
            -label_font $L(font_body) -label_width $L(label_col_w) -label_fill $L(text_body)
        dui add dtext $page $lx [expr {$L(toolbar_y0)+5*$L(lg)}] -tags migrate_error_text -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(danger) -anchor nw -justify left
        dui add dtext $page $lx [expr {$L(toolbar_y0)+7*$L(lg)}] -tags migrate_summary -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_mut) -anchor nw -justify left

        dui add dbutton $page $lx $L(bar_y0) [expr {$lx+$L(btn_w_std)}] $L(bar_y1) -tags cancel \
            -label [translate "Cancel"] -command ::plugins::ShotHistoryEditor::cancel_migrate_confirm \
            -label_font $L(font_button) -style she_btn
        dui add dbutton $page [expr {$rx-$L(btn_w_std)}] $L(bar_y0) $rx $L(bar_y1) -tags migrate_confirm_btn \
            -label [translate "Move"] -command ::plugins::ShotHistoryEditor::confirm_migrate_submit \
            -label_font $L(font_button) -style she_btn
    }

    proc show {page_to_hide page_to_show} {
        ::plugins::ShotHistoryEditor::refresh_migrate_confirm_page $page_to_show 1
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_migrate_result {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x)

        ::plugins::ShotHistoryEditor::_subpage_header $page "Move trash and logs - result" \
            "The outcome of the move. delete_log.txt records it in MIGRATE lines."
        dui add dtext $page $lx $L(list_top) -tags migrate_result_text -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left
        dui add dbutton $page $lx $L(bar_y0) [expr {$lx+$L(btn_w_std)}] $L(bar_y1) -tags page_done \
            -label [translate "Done"] -command {::plugins::ShotHistoryEditor::_return_to_page ShotHistoryEditor_advanced} \
            -label_font $L(font_button) -style she_btn
    }

    proc show {page_to_hide page_to_show} {
        catch { dui item config $page_to_show migrate_result_text -text $::plugins::ShotHistoryEditor::migrate_result_text }
    }
}

# v0.12.0: Empty trash -- typed confirmation (copy of the delete confirm page;
# the entry stays in the top half for the Android keyboard).
namespace eval ::dui::pages::ShotHistoryEditor_purge_confirm {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Empty trash -- Confirm (permanent)" \
            "Removes the plugin trash for good. history/ is never touched." danger
        dui add dtext $page $lx $L(toolbar_y0) -tags purge_instructions -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left
        dui add entry $page $lx [expr {$L(toolbar_y0)+3*$L(lg)}] -tags purge_entry \
            -textvariable ::plugins::ShotHistoryEditor::purge_input \
            -width 20 -font $L(font_primary) -borderwidth 1 -bg $L(entry_danger_bg) -foreground $L(danger) -relief flat \
            -label [translate "Type the number here"] -label_pos [list $lx [expr {$L(toolbar_y0)+2*$L(lg)}]] \
            -label_font $L(font_body) -label_width $L(label_col_w) -label_fill $L(text_body)
        dui add dtext $page $lx [expr {$L(toolbar_y0)+5*$L(lg)}] -tags purge_error_text -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(danger) -anchor nw -justify left

        dui add dbutton $page $lx $L(bar_y0) [expr {$lx+$L(btn_w_std)}] $L(bar_y1) -tags cancel \
            -label [translate "Cancel"] -command ::plugins::ShotHistoryEditor::cancel_purge_confirm \
            -label_font $L(font_button) -style she_btn
        dui add dbutton $page [expr {$rx-$L(btn_w_wide)}] $L(bar_y0) $rx $L(bar_y1) -tags purge_confirm_btn \
            -label [translate "Remove permanently"] -label_fill $L(danger) \
            -command ::plugins::ShotHistoryEditor::confirm_purge_submit \
            -label_font $L(font_button) -style she_btn
    }

    proc show {page_to_hide page_to_show} {
        ::plugins::ShotHistoryEditor::refresh_purge_confirm_page $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_purge_result {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Empty trash - result" \
            "The outcome of Empty trash. purge_log.txt lists every removed file."
        dui add dtext $page $lx $L(list_top) -tags purge_result_text -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left

        dui add dbutton $page $lx $L(bar_y0) [expr {$lx+$L(btn_w_std)}] $L(bar_y1) -tags page_done \
            -label [translate "Done"] -command ::plugins::ShotHistoryEditor::close_purge_result \
            -label_font $L(font_button) -style she_btn
    }

    proc show {page_to_hide page_to_show} {
        ::plugins::ShotHistoryEditor::refresh_purge_result_page $page_to_show
    }
}

# ---------------------------------------------------------------------------
# v0.16.0 -- the Bags pages. Bags is the main page's second tab (same header,
# Shots / Bags tabs top-left, theme toggle top-right, Done exits the plugin);
# Edit bag and Review are its sub-pages with one Back each (F13 helpers, so
# _retheme_all repaints their headers, Backs, pagers and backgrounds). Layout
# comes from the L tokens (_init_layout, _init_bag_layout) only.
# ---------------------------------------------------------------------------

namespace eval ::dui::pages::ShotHistoryEditor_bags {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]

        ::plugins::ShotHistoryEditor::_subpage_header $page "Shot History Editor" \
            "A bag is every shot with the same roaster and bag name."
        ::plugins::ShotHistoryEditor::_add_view_tabs $page bags
        dui add dbutton $page [expr {$rx-$L(btn_h)}] $L(top_btn_y) $rx [expr {$L(top_btn_y)+$L(btn_h)}] \
            -tags btn_theme -label [::plugins::ShotHistoryEditor::_theme_button_face] \
            -command ::plugins::ShotHistoryEditor::toggle_theme \
            -label_font [expr {$L(have_icons) ? $L(font_icon) : $L(font_button)}] \
            -style she_btn

        # v0.18.1: centred in the toolbar row, as on the Shots tab.
        dui add dtext $page $cx $L(toolbar_mid_y) -tags bags_status -text "" \
            -font $L(font_caption) -width $L(toolbar_status_w) -fill $L(text_mut) -anchor center -justify center

        # Six tiles, 3 x 2. Every part starts hidden (the page-show flash
        # trap); _paint_bags_page shows the used ones.
        lassign [::plugins::ShotHistoryEditor::_bag_tile_widths] w_line w_roaster w_footer
        set pad $L(card_pad_x)
        for {set i 0} {$i < $::plugins::ShotHistoryEditor::bag_page_size} {incr i} {
            lassign [::plugins::ShotHistoryEditor::_bag_tile_box $i] x0 y0 x1 y1
            set p bag${i}_
            set tx [expr {$x0 + $pad}]
            ::plugins::ShotHistoryEditor::rounded_rect $page $x0 $y0 $x1 $y1 $L(card_radius) \
                -fill $L(card_bg) -outline $L(card_outline) -width 2 -tags ${p}bg -initial_state hidden
            dui add dtext $page $tx [expr {$y0+$L(bag_roaster_dy)}] -tags ${p}roaster -text "" \
                -font $L(font_caption) -width $w_roaster -fill $L(text_mut) -anchor nw -justify left \
                -initial_state hidden
            set px1 [expr {$x1 - $pad}]
            set px0 [expr {$px1 - $L(bag_pill_w)}]
            set py0 [expr {$y0 + $L(bag_pill_dy)}]
            set py1 [expr {$py0 + $L(bag_pill_h)}]
            ::plugins::ShotHistoryEditor::rounded_rect $page $px0 $py0 $px1 $py1 [expr {$L(bag_pill_h)/2}] \
                -fill $L(inuse_bg) -outline $L(inuse_bg) -width 0 -tags ${p}pill_bg -initial_state hidden
            dui add dtext $page [expr {($px0+$px1)/2}] [expr {($py0+$py1)/2}] -tags ${p}pill_txt \
                -text [translate "IN USE"] -font $L(font_caption) -fill $L(inuse_text) -anchor center \
                -initial_state hidden
            dui add dtext $page $tx [expr {$y0+$L(bag_name_dy)}] -tags ${p}name -text "" \
                -font $L(font_section) -width $w_line -fill $L(text_hi) -anchor nw -justify left \
                -initial_state hidden

            set cy0 [expr {$y0 + $L(bag_chip_dy)}]
            set cy1 [expr {$cy0 + $L(bag_chip_h)}]
            set cym [expr {($cy0 + $cy1) / 2}]
            set lx1 [expr {$tx + $L(bag_lvl_chip_w)}]
            ::plugins::ShotHistoryEditor::rounded_rect $page $tx $cy0 $lx1 $cy1 [expr {$L(bag_chip_h)/2}] \
                -fill $L(chip_bg) -outline $L(chip_bg) -width 2 -tags ${p}lvl_bg -initial_state hidden
            set dx [expr {$tx + $L(bag_dot_dx)}]
            dui add canvas_item oval $page $dx [expr {$cym-$L(bag_dot_r)}] [expr {$dx+2*$L(bag_dot_r)}] \
                [expr {$cym+$L(bag_dot_r)}] -fill $L(dot_unknown) -outline $L(dot_outline) -width 2 \
                -tags ${p}lvl_dot -initial_state hidden
            dui add dtext $page [expr {($tx+$lx1)/2 + $L(bag_dot_r)}] $cym -tags ${p}lvl_txt -text "" \
                -font $L(font_caption) -fill $L(text_hi) -anchor center -initial_state hidden
            set dx0 [expr {$lx1 + $L(md)}]
            set dx1 [expr {$dx0 + $L(bag_date_chip_w)}]
            ::plugins::ShotHistoryEditor::rounded_rect $page $dx0 $cy0 $dx1 $cy1 [expr {$L(bag_chip_h)/2}] \
                -fill $L(chip_bg) -outline $L(chip_bg) -width 2 -tags ${p}date_bg -initial_state hidden
            dui add dtext $page [expr {($dx0+$dx1)/2}] $cym -tags ${p}date_txt -text "" \
                -font $L(font_caption) -fill $L(text_hi) -anchor center -initial_state hidden

            dui add dtext $page $tx [expr {$y0+$L(bag_notes_dy)}] -tags ${p}notes -text "" \
                -font $L(font_caption) -width $w_line -fill $L(text_body) -anchor nw -justify left \
                -initial_state hidden

            set bx1 [expr {$x1 - $pad}]
            set bx0 [expr {$bx1 - $L(bag_btn_w)}]
            set by1 [expr {$y1 - $pad}]
            set by0 [expr {$by1 - $L(card_btn_h)}]
            # Footer lines left of the button: shots, date span, cleaning runs.
            set fy [expr {$y0 + $L(bag_footer_dy)}]
            dui add dtext $page $tx $fy -tags ${p}count -text "" \
                -font $L(font_body) -width $w_footer -fill $L(text_body) -anchor nw -justify left \
                -initial_state hidden
            dui add dtext $page $tx [expr {$fy+$L(body_h)}] -tags ${p}span -text "" \
                -font $L(font_caption) -width $w_footer -fill $L(text_mut) -anchor nw -justify left \
                -initial_state hidden
            dui add dtext $page $tx [expr {$fy+$L(body_h)+$L(caption_h)}] -tags ${p}clean -text "" \
                -font $L(font_caption) -width $w_footer -fill $L(clean_text) -anchor nw -justify left \
                -initial_state hidden
            dui add dbutton $page $bx0 $by0 $bx1 $by1 -tags ${p}edit \
                -label [translate "[::plugins::ShotHistoryEditor::_u 0x270e] Edit bag"] \
                -command "::plugins::ShotHistoryEditor::bag_edit_open $i" \
                -label_font $L(font_button) -style she_btn -initial_state hidden
        }

        # Done exits the plugin, as on the Shots tab; the pager holds the
        # bottom-right corner.
        dui add dbutton $page $lx $L(bar_y0) [expr {$lx+$L(btn_w_std)}] $L(bar_y1) -tags bags_done \
            -label [translate "Done"] -command ::plugins::ShotHistoryEditor::bags_done \
            -label_font $L(font_button) -style she_btn
        ::plugins::ShotHistoryEditor::_add_pager $page bags_prev bags_next \
            {::plugins::ShotHistoryEditor::scroll_bags -1} {::plugins::ShotHistoryEditor::scroll_bags 1}
    }

    proc show {page_to_hide page_to_show} {
        if {![::plugins::ShotHistoryEditor::_page_is_current $page_to_show]} { return }
        ::plugins::ShotHistoryEditor::refresh_bags_page $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_bag_edit {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]
        set NS ::plugins::ShotHistoryEditor

        ::plugins::ShotHistoryEditor::_subpage_header $page "Edit bag" ""

        # Text fields sit in the top half (y < 800 virtual): the Android
        # keyboard covers the bottom. Each has a caption label and, right
        # aligned on the same line, its state note (Changed / differs).
        set col_w [expr {($L(content_w) - $L(be_col_gap)) / 2}]
        set xB [expr {$lx + $col_w + $L(be_col_gap)}]
        set ent_opts [list -font $L(font_body) -borderwidth 1 -relief flat \
            -bg $L(entry_bg) -foreground $L(text_hi) -insertbackground $L(text_hi)]
        foreach {key x w y label var} [list \
            roaster $lx $col_w $L(be_rowA_y) "Roaster" bag_edit_roaster \
            name $xB $col_w $L(be_rowA_y) "Bag name" bag_edit_name] {
            dui add dtext $page $x $y -tags bag_lbl_$key -text [translate $label] \
                -font $L(font_caption) -fill $L(text_mut) -anchor nw -justify left
            dui add dtext $page [expr {$x+$w}] $y -tags bag_st_$key -text "" \
                -font $L(font_caption) -fill $L(value_blue) -anchor ne -justify right
            dui add entry $page $x [expr {$y+$L(be_label_h)}] -tags bag_ent_$key \
                -textvariable ${NS}::$var -canvas_width $w -canvas_height $L(be_entry_h) {*}$ent_opts
        }

        set y $L(be_rowB_y)
        dui add dtext $page $lx $y -tags bag_lbl_notes -text [translate "Notes"] \
            -font $L(font_caption) -fill $L(text_mut) -anchor nw -justify left
        dui add dtext $page $rx $y -tags bag_st_notes -text "" \
            -font $L(font_caption) -fill $L(value_blue) -anchor ne -justify right
        set w [dui add multiline_entry $page $lx [expr {$y+$L(be_label_h)}] -tags bag_ent_notes \
            -textvariable ${NS}::bag_edit_notes -canvas_width $L(content_w) -canvas_height $L(be_notes_h) \
            -wrap word {*}$ent_opts]
        set ${NS}::bag_notes_widget $w
        # The notes box writes its variable only when read, so typing there
        # refreshes the page through a key binding; the entries through traces.
        if {$w ne "" && [llength [info commands $w]]} {
            catch { bind [$w getTextWidget] <KeyRelease> [list +${NS}::_bag_edit_trace] }
        }
        foreach var {bag_edit_roaster bag_edit_name bag_edit_date} {
            trace add variable ${NS}::$var write ${NS}::_bag_edit_trace
        }

        set y $L(be_rowC_y)
        dui add dtext $page $lx $y -tags bag_lbl_date -text [translate "Roast date"] \
            -font $L(font_caption) -fill $L(text_mut) -anchor nw -justify left
        # The date field is narrow: its note starts past the field's right
        # edge on the label line, clear of the label, hint and button.
        dui add dtext $page [expr {$lx+$L(be_date_w)+$L(lg)}] $y -tags bag_st_date -text "" \
            -font $L(font_caption) -fill $L(value_blue) -anchor nw -justify left
        set ey0 [expr {$y+$L(be_label_h)}]
        dui add entry $page $lx $ey0 -tags bag_ent_date -textvariable ${NS}::bag_edit_date \
            -canvas_width $L(be_date_w) -canvas_height $L(be_entry_h) {*}$ent_opts
        dui add dtext $page [expr {$lx+$L(be_date_w)+$L(lg)}] [expr {$ey0+$L(be_entry_h)/2}] -tags bag_hint_date \
            -text [translate "YYYY-MM-DD"] -font $L(font_caption) -fill $L(text_mut) -anchor w
        # Keyboard-safe way out of typing, beside the last field.
        set hy0 [expr {$ey0 + ($L(be_entry_h) - $L(btn_h))/2}]
        dui add dbutton $page [expr {$rx-$L(btn_w_wide)}] $hy0 $rx [expr {$hy0+$L(btn_h)}] -tags bag_hidekb \
            -label [translate "Hide keyboard"] -command ${NS}::bag_hide_keyboard \
            -label_font $L(font_button) -style she_btn

        # Roast level: one choice per button (no keyboard), lower half.
        set y $L(be_rowD_y)
        dui add dtext $page $lx $y -tags bag_lbl_level -text [translate "Roast level"] \
            -font $L(font_caption) -fill $L(text_mut) -anchor nw -justify left
        dui add dtext $page $rx $y -tags bag_st_level -text "" \
            -font $L(font_caption) -fill $L(value_blue) -anchor ne -justify right
        set n [llength [set ${NS}::bag_levels]]
        set gap $L(md)
        set bw [expr {($L(content_w) - ($n-1)*$gap) / $n}]
        set by0 [expr {$y+$L(be_label_h)}]
        set k 0
        foreach lv [set ${NS}::bag_levels] {
            set bx0 [expr {$lx + $k*($bw+$gap)}]
            dui add dbutton $page $bx0 $by0 [expr {$bx0+$bw}] [expr {$by0+$L(card_btn_h)}] -tags bag_lvl$k \
                -label [translate [::plugins::ShotHistoryEditor::_pick [expr {$lv eq ""}] None $lv]] -command "${NS}::bag_pick_level $k" \
                -label_font $L(font_button) -style she_btn
            incr k
        }

        # What the edit touches: three columns on one panel.
        set py0 $L(be_panel_y0)
        set py1 $L(be_panel_y1)
        ::plugins::ShotHistoryEditor::rounded_rect $page $lx $py0 $rx $py1 $L(card_radius) \
            -fill $L(card_bg) -outline $L(card_outline) -width 2 -tags bag_info_bg
        set colw3 [expr {$L(content_w) / 3}]
        set tw [expr {$colw3 - 2*$L(card_pad_x)}]
        foreach k {0 1 2} head {"APPLIES TO" "ALSO UPDATED" "NEVER CHANGED HERE"} role {text_mut clean_text text_mut} {
            set tx [expr {$lx + $k*$colw3 + $L(card_pad_x)}]
            if {$k > 0} {
                set dvx [expr {$lx + $k*$colw3}]
                dui add canvas_item rect $page $dvx [expr {$py0+$L(md)}] [expr {$dvx+$L(be_div_w)}] [expr {$py1-$L(md)}] \
                    -fill $L(card_outline) -outline $L(card_outline) -width 0 -tags bag_info_div$k
            }
            set hy [expr {$py0+$L(card_pad_y)}]
            set vy [expr {$hy+$L(caption_h)+$L(sm)}]
            set dy [expr {$vy+$L(section_h)+$L(sm)}]
            dui add dtext $page $tx $hy -tags bag_info_h$k -text [translate $head] \
                -font $L(font_caption) -width $tw -fill $L($role) -anchor nw -justify left
            dui add dtext $page $tx $vy -tags bag_info_v$k -text "" \
                -font $L(font_section) -width $tw -fill $L(text_hi) -anchor nw -justify left
            dui add dtext $page $tx $dy -tags bag_info_d$k -text "" \
                -font $L(font_caption) -width $tw -fill $L(text_mut) -anchor nw -justify left
        }

        # One exit (Back to Bags); Review on the right, disabled until a
        # field changes.
        ::plugins::ShotHistoryEditor::_add_back $page ${NS}::bag_edit_back
        dui add dbutton $page [expr {$rx-$L(btn_w_wide)}] $L(bar_y0) $rx $L(bar_y1) -tags bag_edit_review \
            -label [translate "Review changes"] -command ${NS}::bag_review_open \
            -label_font $L(font_button) -style she_btn
        catch { dui item enable_or_disable 0 $page bag_edit_review* -initial 1 }
    }

    proc show {page_to_hide page_to_show} {
        if {![::plugins::ShotHistoryEditor::_page_is_current $page_to_show]} { return }
        ::plugins::ShotHistoryEditor::_bag_default_pick
        ::plugins::ShotHistoryEditor::_paint_bag_edit $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_bag_review {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x); set cx [expr {($lx+$rx)/2}]
        set NS ::plugins::ShotHistoryEditor

        ::plugins::ShotHistoryEditor::_subpage_header $page "Review bag changes" ""

        # One row per bag field: field, now (over every file), after Save.
        set fx [expr {$lx + $L(card_pad_x)}]
        set nx [expr {$lx + $L(rv_x_now)}]
        set ax [expr {$lx + $L(rv_x_after)}]
        set y $L(rv_head_y)
        foreach {tag x text} [list rv_h_field $fx "FIELD" rv_h_now $nx "NOW" rv_h_after $ax "AFTER SAVE"] {
            dui add dtext $page $x $y -tags $tag -text [translate $text] \
                -font $L(font_caption) -fill $L(text_mut) -anchor nw -justify left
        }
        set dy [expr {$L(rv_row_y0) - $L(sm)}]
        dui add canvas_item rect $page $lx $dy $rx [expr {$dy+$L(be_div_w)}] \
            -fill $L(card_outline) -outline $L(card_outline) -width 0 -tags rv_div_head
        for {set k 0} {$k < 5} {incr k} {
            set y0 [expr {$L(rv_row_y0) + $k*$L(rv_row_h)}]
            set ym [expr {$y0 + $L(rv_row_h)/2}]
            dui add dtext $page $fx $ym -tags rv_f$k -text "" -font $L(font_primary) \
                -fill $L(text_hi) -anchor w -justify left -initial_state hidden
            dui add dtext $page $nx $ym -tags rv_n$k -text "" -font $L(font_body) \
                -fill $L(text_body) -anchor w -justify left -initial_state hidden
            dui add dtext $page $ax $ym -tags rv_a$k -text "" -font $L(font_body) \
                -fill $L(value_blue) -anchor w -justify left -initial_state hidden
            set ly [expr {$y0 + $L(rv_row_h) - $L(be_div_w)}]
            dui add canvas_item rect $page $lx $ly $rx [expr {$ly+$L(be_div_w)}] \
                -fill $L(card_outline) -outline $L(card_outline) -width 0 -tags rv_d$k -initial_state hidden
        }
        dui add dtext $page $lx $L(rv_warn_y) -tags rv_warn -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(warn) -anchor nw -justify left

        # Two panels: what Save will do, and the files.
        set pw [expr {($L(content_w) - $L(md)) / 2}]
        set py0 $L(rv_panel_y0)
        set py1 $L(rv_panel_y1)
        foreach {bgtag ttag btag ntag x} [list rv_do_bg rv_do_title rv_do_text rv_do_note $lx \
                                               rv_fl_bg rv_fl_title rv_fl_text rv_fl_more [expr {$lx+$pw+$L(md)}]] {
            set tx [expr {$x + $L(card_pad_x)}]
            set tw [expr {$pw - 2*$L(card_pad_x)}]
            ::plugins::ShotHistoryEditor::rounded_rect $page $x $py0 [expr {$x+$pw}] $py1 $L(card_radius) \
                -fill $L(card_bg) -outline $L(card_outline) -width 2 -tags $bgtag
            dui add dtext $page $tx [expr {$py0+$L(card_pad_y)}] -tags $ttag -text "" \
                -font $L(font_section) -width $tw -fill $L(text_hi) -anchor nw -justify left
            dui add dtext $page $tx $L(rv_body_y) -tags $btag -text "" \
                -font $L(font_body) -width $tw -fill $L(text_body) -anchor nw -justify left
            dui add dtext $page $tx $L(rv_note_y) -tags $ntag -text "" \
                -font $L(font_caption) -width $tw -fill $L(text_mut) -anchor nw -justify left
        }
        dui item config $page rv_do_title -text [translate "What Save will do"]

        ::plugins::ShotHistoryEditor::_add_back $page ${NS}::bag_review_back
        # Save opens the typed confirmation; enabled only by the snapshot.
        dui add dbutton $page [expr {$rx-$L(btn_w_wide)}] $L(bar_y0) $rx $L(bar_y1) -tags rv_save \
            -label [translate "Save"] -command ${NS}::bag_save_open \
            -label_font $L(font_button) -style she_btn
        catch { dui item enable_or_disable 0 $page rv_save* -initial 1 }
    }

    # Painted before every forward open and Back; this only catches a direct
    # load (DevBridge): the newest bag, its snapshot built here.
    proc show {page_to_hide page_to_show} {
        if {![::plugins::ShotHistoryEditor::_page_is_current $page_to_show]} { return }
        if {$::plugins::ShotHistoryEditor::bag_cur eq ""} {
            ::plugins::ShotHistoryEditor::_bag_default_pick
        }
        if {$::plugins::ShotHistoryEditor::bag_cur ne "" && ![::plugins::ShotHistoryEditor::_bag_plan_matches]} {
            ::plugins::ShotHistoryEditor::_bag_plan_build
        }
        ::plugins::ShotHistoryEditor::_paint_bag_review $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_bag_confirm {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x); set rx $L(right_x)
        set NS ::plugins::ShotHistoryEditor

        ::plugins::ShotHistoryEditor::_subpage_header $page "Save bag changes" "" danger
        dui add dtext $page $lx $L(bc_changes_y) -tags bc_changes -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left
        dui add dtext $page $lx $L(bc_warn_y) -tags bc_warn -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(warn) -anchor nw -justify left
        dui add dtext $page $lx $L(bc_instr_y) -tags bc_instr -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left
        # The typed count and a keyboard-safe way out of typing, top half.
        dui add entry $page $lx $L(bc_entry_y) -tags bc_entry \
            -textvariable ${NS}::bag_confirm_input \
            -canvas_width $L(be_date_w) -canvas_height $L(be_entry_h) \
            -font $L(font_primary) -borderwidth 1 -relief flat \
            -bg $L(entry_danger_bg) -foreground $L(danger) -insertbackground $L(danger)
        set hy0 [expr {$L(bc_entry_y) + ($L(be_entry_h) - $L(btn_h))/2}]
        dui add dbutton $page [expr {$rx-$L(btn_w_wide)}] $hy0 $rx [expr {$hy0+$L(btn_h)}] -tags bc_hidekb \
            -label [translate "Hide keyboard"] -command ${NS}::bag_hide_keyboard \
            -label_font $L(font_button) -style she_btn
        dui add dtext $page $lx $L(bc_error_y) -tags bc_error -text "" \
            -font $L(font_caption) -width $L(content_w) -fill $L(danger) -anchor nw -justify left
        # What happens, lower half.
        set py0 $L(bc_panel_y0)
        set py1 [expr {$L(bar_y0) - $L(md)}]
        ::plugins::ShotHistoryEditor::rounded_rect $page $lx $py0 $rx $py1 $L(card_radius) \
            -fill $L(card_bg) -outline $L(card_outline) -width 2 -tags bc_panel_bg
        dui add dtext $page [expr {$lx+$L(card_pad_x)}] [expr {$py0+$L(card_pad_y)}] -tags bc_files -text "" \
            -font $L(font_body) -width [expr {$L(content_w)-2*$L(card_pad_x)}] -fill $L(text_body) \
            -anchor nw -justify left

        # A confirm page keeps Cancel at left_x; the Save is on the far right.
        dui add dbutton $page $lx $L(bar_y0) [expr {$lx+$L(btn_w_std)}] $L(bar_y1) -tags bc_cancel \
            -label [translate "Cancel"] -command ${NS}::bag_confirm_cancel \
            -label_font $L(font_button) -style she_btn
        dui add dbutton $page [expr {$rx-$L(btn_w_wide)}] $L(bar_y0) $rx $L(bar_y1) -tags bc_save \
            -label [translate "Save"] -label_fill $L(danger) -command ${NS}::bag_confirm_submit \
            -label_font $L(font_button) -style she_btn
        catch { dui item enable_or_disable 0 $page bc_save* -initial 1 }
    }

    # Painted by bag_save_open before it loads; this only repaints from the
    # snapshot (never reads a file), and only while the page is on screen.
    proc show {page_to_hide page_to_show} {
        if {![::plugins::ShotHistoryEditor::_page_is_current $page_to_show]} { return }
        ::plugins::ShotHistoryEditor::_paint_bag_confirm $page_to_show
    }
}

namespace eval ::dui::pages::ShotHistoryEditor_bag_result {
    proc setup {} {
        set page [namespace tail [namespace current]]
        upvar #0 ::plugins::ShotHistoryEditor::L L
        ::plugins::ShotHistoryEditor::_page_bg $page
        set lx $L(left_x)
        ::plugins::ShotHistoryEditor::_subpage_header $page "Bag save result" ""
        dui add dtext $page $lx $L(toolbar_y0) -tags br_text -text "" \
            -font $L(font_body) -width $L(content_w) -fill $L(text_body) -anchor nw -justify left
        # Done ends the flow (result pages keep Done).
        dui add dbutton $page $lx $L(bar_y0) [expr {$lx+$L(btn_w_std)}] $L(bar_y1) -tags br_done \
            -label [translate "Done"] -command ::plugins::ShotHistoryEditor::bag_result_done \
            -label_font $L(font_button) -style she_btn
    }

    proc show {page_to_hide page_to_show} {
        if {![::plugins::ShotHistoryEditor::_page_is_current $page_to_show]} { return }
        ::plugins::ShotHistoryEditor::_paint_bag_result $page_to_show
    }
}
