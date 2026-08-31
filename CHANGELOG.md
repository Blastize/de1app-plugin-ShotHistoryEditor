# Changelog

## v0.8.0 - dark mode

**Safety: no change to the write capability.** The one new persisted
value is `theme` in the plugin's own settings.tdb (its first persisted
setting), saved on each explicit toggle tap. History files, SDB and the
trash mechanism are untouched.

- A sun/moon button on the main page (top-LEFT corner — the top-right
  slot belongs to the Select mode button here) switches all 13 pages
  between a light and a dark palette instantly; the choice persists
  across restarts.
- Every color the plugin paints moved from scattered literals into one
  `_apply_palette` proc (the offline harness enforces that no palette
  literal appears anywhere else). All of this plugin's colors are
  creation-time, so `_retheme_all`'s bare-tag walk is the complete
  repaint: page backgrounds, all text roles, the card rows, the trash
  and inspector row lists, both entries (with their attached labels),
  every button face, and the three danger-labeled buttons (Confirm
  Delete / Save Change), whose red lightens on dark for contrast — as
  do the warn amber and the value blue.
- Two previously untagged labels on the Edit Preview page (Field
  selector / Current value) gained tags so the repaint can reach them.
- Offline harness: scratchpad verify_she_v080.tcl, 79 checks.

## v0.7.1 - a restored file's modification time is stamped

**Safety: the write capability is UNCHANGED — one `file mtime` stamp on a
file this plugin has just legitimately moved back into place. No content is
touched. This is the exact mechanism the edit path has used since v0.6.0.**

`file rename` preserves the original's mtime, and SDB's populate only
re-reads a shot file whose mtime is NEWER than the one it stored. Normally
harmless — but if the shot's path was rewritten while it sat in trash, SDB
holds the REWRITE's metadata, and the restored original, being older on the
clock, would never be re-read. Seen for real on 2026-08-24: the core's
flush-save bug parked a corpse under a trashed shot's filename; after the
restore, Grind Advisor kept computing from the corpse's row ("yield (no
actual)") although the restored file plainly held `drink_weight 22.2`. That
session was fixed by hand-stamping over adb; this version makes
`restore_batch` stamp each successfully restored file itself, right before
`_notify_downstream` triggers the resync that reads it.

`tools/check_refresh.tcl` section H proves it: a shot whose file is a day
old on the clock is deleted and restored, and the restored file's mtime
must postdate the restore — with the old `file rename`-only code it keeps
the day-old stamp and SDB would skip it.

## v0.7.0 - the Lumen home page is told about edits and deletes too

**Safety: the write capability is UNCHANGED, and nothing was added to it.
This version widens the v0.6.3 notification — it adds a second guarded,
read-only downstream call, no new write of any kind.**

Owner goal: edit or delete a shot here, return to the Lumen home screen, and
see everything updated — the Grind Advisor card, the chart, and the LAST
SHOT card. v0.6.3 wired Grind Advisor; the skin's chart and card kept
showing the old (or deleted) shot, because the skin only read the newest
shot file at startup.

* **`_notify_downstream`** wraps the existing `_refresh_grind_advisor` and
  then calls **`::lumen::refresh_after_history_change`** (new in Lumen
  0.28.0), in that order on purpose: Grind Advisor's step resyncs SDB, and
  Lumen's bag cycler reads SDB. All four call sites (edit, delete, partial
  delete, restore) switched from the bare Grind Advisor call to this.
* Same guards, same contract as v0.6.3: `info procs` existence check (a
  different skin simply skips the step), errors logged and swallowed —
  this plugin's own save/delete has already succeeded by then, and Grind
  Advisor's summary note survives a Lumen failure.
* **`tools/check_refresh.tcl` section G** proves it with a counter stub:
  a delete reaches Lumen exactly once (and Grind Advisor still exactly
  once), an edit reaches it, nothing-moved does not, and both the
  absent-Lumen and throwing-Lumen cases leave the delete successful with
  the Grind Advisor note intact. Sections A–E pass unchanged, which is the
  regression proof: with no `::lumen` namespace the wrapper degrades to
  exactly the v0.6.3 behaviour.

## v0.6.4 - the startup line said "vv0.6.3" (log text only)

**Safety: nothing changed. One string literal and one comment. No code path,
no write, no page.**

Seen in the tablet log after the v0.6.3 restart:

```
INFO: ShotHistoryEditor: started card browser vv0.6.3 (edit save + soft delete active)
```

`plugin.tcl`'s message prepends a literal `v`, and the `version` variable's
VALUE carried one too. Fixed on the variable, not the message: this plugin was
the only one of the 24 on the tablet storing a prefixed version — every other
one stores a bare number. The core reads that variable solely to decide
whether a plugin's metadata loaded (`plugins.tcl:204`) and never displays it,
so nothing outside this plugin depended on either format.

`tools/check_refresh.tcl` section F now rebuilds the startup line from
`plugin.tcl`'s own literal and fails on a doubled prefix.

## v0.6.3 - a deleted shot now stops counting towards the grind recommendation

**Safety: the write capability is UNCHANGED, and nothing was added to it.
Soft delete still means moving `history/<shot>.shot` and its matching
`history_v2/<shot>.json` into this plugin's own `trash/` folder, restorable,
with a manifest and an audit log. The edit path still writes exactly one
targeted line inside a `.shot` file's settings block. No SQL is issued by this
plugin, nothing is permanently deleted, and this version adds no new write of
any kind — it adds a NOTIFICATION to another plugin.**

Owner-reported from the tablet: deleting a shot did not change the grind
recommendation, *"just like last time when I edited"*.

Last time was v0.6.0, which found that every edit this plugin had ever made
was invisible to SDB and fixed it — the file's mtime is stamped, and Grind
Advisor is told the edit happened. That call went into the edit path and
**nowhere else**. `perform_delete_batch` moved the files, wrote its manifest
and log, and returned without telling anyone. `restore_batch` had the same
gap in reverse.

Everything downstream was already correct, which is what makes this small:

* SDB's own `populate` flags a vanished file `removed=1` by **absence alone**
  (`SDB.tcl`, "Check files deleted from disk"). Deleting needs no mtime trick,
  unlike editing.
* Grind Advisor already filters that column in its SQL, and again defensively
  in Tcl.

So the deleted shots kept feeding the regression purely because nobody asked
for the resync. The notification was the only missing link.

### What changed

* **`_refresh_grind_advisor`** — the guarded call to
  `::plugins::GrindAdvisor::refresh_from_history`, lifted out of
  `perform_metadata_edit` into one shared proc. Same guards as before: absent
  plugin and thrown error both leave this plugin's own result a success,
  because its work is finished by the time this runs.
* **`perform_delete_batch`** calls it once per **batch**, after the manifest is
  written, and only when files actually moved — the resync rescans the whole
  history folder, so it is not something to do per file or on a batch that
  moved nothing. The partial-failure path refreshes too: files that already
  moved have changed the history folder whether or not the batch finished.
* **`restore_batch`** calls it when something actually came back. A restore
  blocked entirely by name collisions changes nothing and asks for nothing.
* **The Delete Result page reports it**, the way the Edit Result page already
  did — "Grind Advisor: SDB resynced, recomputed: 7.5". Before this the
  deleted shots kept counting and nothing on screen said so.
* **`tools/check_refresh.tcl`** drives the real `perform_delete_batch` and
  `restore_batch` against a temporary history folder with
  `refresh_from_history` replaced by a counter, asserting all of it: one
  refresh per batch regardless of size, none when nothing moved, none on a
  collision-blocked restore, and the plugin still reporting its own success
  when Grind Advisor is missing or throws. Negative-tested against the v0.6.2
  wiring, where it fails on exactly the delete and restore cases while the
  edit case still passes — the owner's report, reproduced.

**One proc, three paths, on purpose.** Two copies of this logic is how the
delete path came to be missed in the first place.

## v0.6.2 - every page's way out is the bottom-left corner (display only)

**Safety: no write behavior changed. Button x coordinates only.**

v0.6.1 moved Edit Preview's Done; the owner asked for the rest. Every page's
exit control now sits at the far left, aligned with the card list's own Done
(`bar_left`), so leaving a flow is the same corner every time however deep it
went:

| page | now leads with |
|---|---|
| Detail | Done, then Back / Prev / Next, then Edit Metadata Preview |
| Diagnostics, Help | Done, then Back / Prev / Next |
| Trash | Done, then Back / ◀ Prev |
| Recent | Done, then Back |
| Edit Result, Delete Result | Done |
| Edit Confirm | Cancel (Save Change stays right) |
| Delete Review, Delete Confirm | Cancel (Continue / Delete stay right) |

**The confirm pages move Cancel, not the forward button.** Cancel is the way
out — the role Done plays elsewhere — and the destructive button must not be
where a thumb is repeatedly tapping to leave. Delete Review and Delete Confirm
were not in the owner's list, but leaving them behind while their edit-flow
twin moved would have been a worse answer than the one asked for.

Every button keeps its width, including Detail's wide **Edit Metadata
Preview**: the row gains on the right exactly what it lost on the left, so
that button is 696px before and after.

### tools/check_bars.tcl

New. It sources the real plugin with the framework stubbed, runs all 13
pages' `setup{}`, and prints every bottom bar left to right, asserting the row
starts at the left margin, no two buttons overlap, and nothing runs past the
right margin. This kind of change is easy to half-do — one page missed, or a
row left starting at the old x with a button dropped on top of it — and eight
bars cannot be checked by eye. It caught exactly that: the first cut put Done
at the left of Diagnostics and Help *on top of* Back, which still had `set x
$lx`.

## v0.6.1 - Edit Preview's Done moves to the far left (display only)

**Safety: no write behavior changed. This is one button's x coordinate.**

Owner request: *"in the shot history editor, edit preview page, move the done
button to the far left, it makes it easier this way when i click done and
click done again the same place."*

Leaving the editor is two taps: Done on Edit Preview, then Done on the card
list it returns to. The card list's Done is `bar_left` — the far left, per the
design system's "Done left / Advanced right" — while Edit Preview's was at the
far right, so the two taps were in opposite corners of the screen. They are
the same spot now.

**Back stays beside Done** rather than moving to the far right, because on
this page the two run the identical command (`page_done` reuses
`back_from_edit_preview`). Splitting them across the bar would advertise a
difference that does not exist.

Geometry checked against the plugin's own `_init_layout`: Done `92..492`,
Back `512..912`, page edge `2468` — no overlap, no overflow, and Done's left
edge is exactly the card list's `left_x`, which is what makes the two taps
land together.

The other dialog pages (Edit Confirm, Edit Result, Delete Result, Detail,
Trash, Diagnostics, Help) still carry Done at the far right. Same
double-tap mismatch applies to their exits; left alone as out of scope for
this request.

## v0.6.0 - an edited shot now LOOKS edited (and Grind Advisor follows it)

**Safety: the write capability is unchanged. This plugin still writes exactly
one thing — the single targeted line inside `history/<shot>.shot`'s settings
block — plus its own backups, manifest and log. `history_v2` is untouched, no
SQL is issued, and nothing is deleted. Two things were added on top of that
same save: the file's modification TIME is stamped, and Grind Advisor is told
the edit happened.**

### The bug: every edit this plugin has ever made was invisible to SDB

Owner-reported: correcting a shot's grind changed nothing downstream, even
after Grind Advisor v3.9.0 added an explicit resync-and-recalculate button.
That button reported `SDB resynced, recomputed: 5.6` and produced the same
number as before.

Measured on the tablet, 2026-08-19:

| | value |
|---|---|
| `edit_log.txt` | `20260818T164530 EDIT OK filename=20260818T164430 field=grinder_setting old=7.5 new=8` |
| the file's content | `grinder_setting 8` — the edit is really there |
| the file's mtime | **1787057093** = 16:44:53, when the app first wrote the shot |
| SDB's row | `grinder_setting '7.5'`, `file_modification_date` **1787057093** |

The edit was made at 16:45:30 and the file's timestamp still said 16:44:53.
`file rename` landed the replacement carrying the **original's** timestamp:
Tcl's rename falls back to a copy on this storage, and Tcl's copy preserves
file times.

SDB re-reads a `.shot` only when `file mtime > file_modification_date`
(`SDB.tcl:2060`). Those two numbers were byte-identical, so it skipped the
file — and would have skipped it forever. **SDB's own "Resync database to
history" button could never have picked up an edit made by this plugin
either.** Every edit in `edit_log.txt`, going back to July, is in the same
position.

### The fix

One `file mtime $path [clock seconds]` on the file this plugin has just
legitimately rewritten. No content is touched. It runs **after** the
post-rename verification, so a save that failed and was rolled back never
stamps anything, and it is wrapped in `catch` — a stamp that fails logs a
NOTICE and does not fail the save, which has already succeeded by then.

### Grind Advisor is now told automatically

Answering the owner's *"why not auto recalculate?"*: on a successful save this
plugin calls `::plugins::GrindAdvisor::refresh_from_history` when that plugin
is installed — guarded on both existence and errors, because this plugin's own
save has already succeeded and must report success whatever another plugin
does. The result line is shown on the save-result page (`Grind Advisor: SDB
resynced, recomputed: 6.0`).

An edit is exactly the right moment to spend a full history rescan: it happens
once, when you asked for it. A display tick is not — which is why Grind
Advisor does not do this on every recommendation lookup.

### Existing edits

Files edited before this version still carry their original timestamps, so
SDB still cannot see them. Re-saving the field in this plugin fixes each one:
there is no no-op guard, so saving the same value again is a real write and
stamps the time.

## v0.5.4 - Pass 5.4 Theme/Contrast Bugfix (display only)

Fixes the "inverted colors" report: under the Lumen skin the pages showed a
near-black background with dark text, and every button lost its shape (bare
labels, the card Edit buttons effectively invisible).

- **Root cause (confirmed from the app log, not guessed):** Lumen's DYE
  integration runs `dui theme set DYE_Lumen` (skins/Lumen/skin.tcl:1831)
  when the DYE plugin gets styled, and never restores the current theme.
  Plugins that load after that point (this one: ShotHistoryEditor at
  21:53:35.705 vs the switch at 21:53:35.443) register any un-themed
  `dui aspect set` styles into DYE_Lumen. This plugin's pages are
  `-theme default`, and aspect lookup falls back from a named theme toward
  default, never the other way -- so `she_btn`'s shape resolved empty and
  **no button background was drawn at all**. This is exactly the bug
  BeanScanner found and fixed in its v0.1.2 (its comment block predicted
  it applies to any late-loading plugin; GrindAdvisor only escapes it
  because it happens to load before the theme switch).
- **Second defect, same report:** fpdialog pages carry no background of
  their own in this core build, so they show whatever page or canvas lies
  beneath -- near-black under Lumen dark. The light-design pages were
  never actually painting their grey background.
- **Fix (copied verbatim from BeanScanner's proven pattern):** `she_btn`
  is now registered with `-theme default` and explicit
  fill/disabledfill + label fills (stock periwinkle/white, so the look is
  identical to the plugin's original verified appearance); new `_page_bg`
  paints an explicit full-page grey (#d5d6e3) as the first item of every
  one of the 13 pages; color tokens added to the layout block.
- Display-only: no navigation, no math, no file operations changed. Safety
  status unchanged -- same write capabilities as v0.5.0 (metadata save +
  soft delete), nothing new.

## v0.5.1 / v0.5.2 / v0.5.3 - navigation bugfixes

Recorded in plugin.tcl's header at the time; summarized here for
completeness: 5.1 loops `close_dialog` per level in `_return_to_page`;
5.2 applied GrindAdvisor v1.8.8's flow-interruption navigation pattern;
5.3 reverted 5.2's direct `dui page load` to stacked ancestors (core
page_stack truncation bug, confirmed in de1app-core source) in favor of
one-level-at-a-time unwinding, and made the Done capture skip this
plugin's own pages.

## v0.5.0 - Pass 5.0 Real Metadata Save

Adds real metadata save: writing one settings{} key at a time into history/<filename>.shot, with backup, verified write, edit manifest, and audit log; SDB and history_v2 remain untouched; soft delete/trash/restore from v0.4.0/v0.4.1 are unchanged.

- **Step 1 findings:**
  - `.shot` format: a flat `key value` line per top-level entry, plus one `settings { ... }` block holding the user-facing metadata in the same style. The 3 sample files in `history/` all contain a nested `read_only_backup {...}` sub-value inside the settings block that spans many lines and is unbalanced within any single line -- a naive "stop at the first bare closing-brace line" scan (which is exactly what this plugin's existing `read_legacy_settings`/`_parse_settings_file` already does, harmlessly for reading only because every editable field's key sorts alphabetically before `read_only_backup`) would truncate partway through the real block. Writing against that truncated boundary would risk corrupting the file, so the new write path tracks brace depth properly (`_settings_block_bounds`/`_find_settings_key_line`) to find the block's true end and the exact target key's line, verified against the real sample files (true end at line 490, not the first bare `}` at line 409).
  - `plugins/SDB/SDB.tcl:2948` calls a core app proc `modify_shot_file $path new_settings` (via `get_shot_file_path`) to edit `.shot` files for category changes -- confirming the app itself treats targeted `.shot` edits as normal. Neither proc's implementation exists in this workspace, and SDB's call site immediately follows it with a `db eval "UPDATE ..."` against SDB in the same breath -- so, per "do not guess the DE1app plugin API" and "SDB stays read-only", this pass does not call `modify_shot_file` and instead implements its own self-contained, verified read-modify-temp-write-rename cycle.
  - `history_v2/<filename>.json` is **not** written by this pass (same evidence as the delete pass: nothing in this workspace reads or depends on it, and its meta.bean/meta.grinder key names differ from the .shot settings block, so keeping them in sync would need a second write path with no proven need). A saved field can leave history_v2 showing a stale value until a future pass addresses it -- documented in Help/README.
  - SDB is never written to, so the card list and Detail page's SDB-sourced values would otherwise keep showing the pre-edit value. Reused the delete pass's manifest-overlay pattern: `edit_manifest.txt` entries are read back and overlaid onto SDB-sourced fields before display (`_all_edit_overlays`/`_apply_edit_overlay`), so the user sees their correction immediately even though SDB itself is untouched and may resync on its own.
  - **Bug found and fixed in existing code during Step 1 testing:** `read_legacy_settings`/`_parse_settings_file`'s two brace-comparisons (`$trimmed eq "settings {"` and `$trimmed eq "}"`) only ever survived Tcl's source-time brace-matching by an accidental cancellation between the two, and threw a runtime "invalid character '}' in expression" error the first time they were actually exercised against a real multi-line `.shot` file (never triggered before because this plugin's own tests only used single-line synthetic settings{} fixtures). Fixed by escaping both literal braces (`\{`/`\}`); behavior is unchanged, this only fixes a latent crash that a real file would have hit in every prior version's Detail/Diagnostics read path.
- **perform_metadata_edit:** validates the field against the existing safe `editable_fields` allowlist and the filename against the existing `_safe_filename` check; backs up the whole original file to `plugins/ShotHistoryEditor/backups/<timestamp>_<batchid>/` before any write; builds the new file content in memory (only the one targeted line changes); writes it to a temp file in the same directory and verifies it with `_parse_settings_file` -- if verification fails, the original is never touched and the temp file is left behind for inspection (never `file delete`); only then atomically `file rename`s the temp file over the original; re-verifies the now-current file and, in the unlikely case that also fails, automatically restores the original by renaming the backup back into place. Every save (or failed-then-restored save) is appended to `edit_manifest.txt` (on success) and `edit_log.txt` (always).
- **UI flow:** Edit Metadata Preview (unchanged: pick field, type new value, Preview Change) gained one new button, **Save Change**, leading to a new Before/After **Confirm** page (exact shot, exact file, before/after values, numeric-mismatch warning, Cancel / danger-colored Save Change) -> **Result** page (saved/failed message, backup path) -> back to wherever Edit Preview was entered from. Cancel at Confirm and Done at Result, and Edit Preview's own Back button, all now use the v0.4.1-proven `_return_to_page` navigation helper instead of `open_page`, since this mini-flow can be 2-6 pages deep in the dialog stack -- exactly the class of bug fixed in v0.4.1.
- An empty new value is rejected before any file operation (`open_edit_confirm` simply does nothing); numeric-field warnings are shown but do not block a save, matching the existing preview behavior.
- Safety status: grepped the whole plugin -- still zero SQL write keywords (INSERT/UPDATE/DELETE/ALTER/DROP/CREATE TABLE/VACUUM/REINDEX) and zero `file delete` calls. File writes exist only in: the temp-file + atomic rename of the one targeted `.shot` file, the plugin's own `backups/`, `edit_manifest.txt`, and `edit_log.txt`. Verified with a headless sandbox test against the real sample `.shot` files: editing a field changes exactly one line (byte-for-byte identical otherwise, including the raw sensor arrays); the backup matches the pre-edit original exactly; Cancel at both Confirm and Review-equivalent steps performs zero file operations; a simulated post-rename verification failure correctly auto-restores from backup; the edited value overlays correctly onto the card list and Detail page's SDB section while a synthetic "SDB" value stays stale until overlaid.

## v0.4.1 - Pass 4.1 Delete-Flow Navigation Bugfix

Navigation/exit-wiring fix only; no changes to delete/restore/trash logic or SDB reading.

- **Fix:** on the Delete Result page, Done did nothing (no error, no crash, just no visible reaction). Root cause: `close_delete_result` called `open_page ShotHistoryEditor_settings`, which tries `dui page open_dialog`/`load`/`show` in order and stops at the first one that doesn't throw. By the time Result's Done is tapped, `ShotHistoryEditor_settings` is already open 3 levels down the dialog stack (settings -> delete_review -> delete_confirm -> delete_result). Calling `open_dialog` on a page already in the stack does not throw -- so `open_page`'s `catch` treats it as success -- but it performs no real page transition either, so the settings page's `show{}` (which resets selection mode and reloads the list) never runs. Every other proven-working exit in this plugin, and the reference plugin GrindAdvisor's `_close_settings_dialog`/`_close_subpage_dialog` (GrindAdvisor.tcl:412-439), instead exit a stacked dialog with `dui page close_dialog`; GrindAdvisor's own comments confirm close_dialog "reveals whatever page the framework currently considers current," and GrindAdvisor restricts `open_dialog`-style entry to genuine top-level entry only, never to returning to an ancestor page. A headless test confirmed the alternative theory (an uncaught error in `refresh_main_page`/`show{}` with a populated `trash_manifest.txt`) does not hold -- that path runs cleanly regardless of manifest contents.
- **Fix:** added `_return_to_page`, reusing GrindAdvisor's own proven two-step recovery technique: call `dui page close_dialog` once (lets the framework release its real dialog bookkeeping), then check `dui page current`; if it didn't land exactly on the target (the delete flow can be several pages deep, unlike the 1-level cases elsewhere in this plugin), force it with `dui page load` -- never `open_dialog`, which is what silently failed. Applied to Delete Result's Done, Delete Review's Cancel, and Delete Confirm's Cancel (all three share the identical `open_page`-to-an-already-stacked-ancestor pattern), and to Advanced's Back button (same pattern, explicitly flagged for a shared-fault check; low-risk since the corrective `load` branch only fires when a plain `close_dialog` didn't already land on the target, so any case that happened to already work is unaffected). Diagnostics/Help/Detail/Recent's own Back buttons use the same `open_page`-to-immediate-parent shape but were not reported broken and were left untouched, per bugfix scope.
- Verified with a headless simulation of the exact reported failure mode (open_dialog succeeding without a real transition): `_return_to_page` correctly falls through to `dui page load` and lands on the target; at 1-level depth (matching Review Cancel/Advanced Back) the corrective branch never fires, confirming zero behavior change for cases that already worked. Re-ran the full delete/cancel/restore end-to-end test from v0.4.0 -- `perform_delete_batch`/`restore_batch`/manifest/log output are byte-identical to before.
- No layout tokens, fonts, coordinates, delete/restore/trash logic, or SDB reading changed. Grepped the plugin: no SQL write keywords, no `file delete` calls (only `file rename`, unchanged from v0.4.0).

## v0.4.0 - Pass 4.0 Real Soft Delete

Adds soft delete: file moves to plugin trash with two-step confirmation, manifest, audit log, and restore; no permanent deletion; no metadata editing; SDB untouched.

- **Step 1 finding:** grepped `plugins/SDB/SDB.tcl`, `plugins/GrindAdvisor/GrindAdvisor.tcl`, and `plugins/visualizer_upload/plugin.tcl` for `history_v2`/`.json` -- zero matches anywhere. SDB's own resync/rebuild path (`::plugins::SDB::populate`/`::plugins::SDB::create`) is driven entirely from `history/*.shot`; nothing indexes, watches, or rebuilds from `history_v2` filenames, and `history_v2/` itself has no manifest/index file, only loose per-shot json files. Decision: this pass moves **both** `history/<filename>.shot` and its matching `history_v2/<filename>.json` (when present) together into the same trash batch -- there is no functional reason to leave an orphaned json with zero consumers.
- **Trash structure:** `plugins/ShotHistoryEditor/trash/<timestamp>_<batchid>/` holds moved files; `plugins/ShotHistoryEditor/trash_manifest.txt` has one `timestamp|original_path|trash_path|batch_id` line per moved file; `plugins/ShotHistoryEditor/delete_log.txt` is a human-readable audit log. All three live under the plugin folder and are excluded from `filelist.txt`/packaging, per CLAUDE.md.
- **File operations are move/rename only.** `perform_delete_batch` uses `file rename` exclusively; `file delete` is never called on a history file anywhere in this plugin. If a move fails partway through a batch, the whole batch stops immediately; every file that already moved is still recorded in the manifest (nothing moved is ever left untracked), and the failure is reported back to the user.
- **Confirmation flow replaces the old "Delete Preview":** selecting shots and tapping Delete now opens **Review** (Step 1: exact shot list with date/time + exactly which files will move, e.g. "history/x.shot, history_v2/x.json" or "history/x.shot only"; Cancel/Continue) then **Confirm** (Step 2: type the exact number of shots being deleted into a field in the top half of the screen, then tap the danger-colored Confirm Delete; Cancel always available). Typed confirmation was chosen over hold-to-confirm because no press-and-hold/progress-timer UI pattern exists anywhere in this workspace to build on, and the spec explicitly allows a typed count as the reliable fallback for this first destructive-capability pass. On success, a **Result** page reports how many files moved and the trash path, then returns to the main page (which unconditionally exits selection mode and reloads the list).
- **List consistency:** SDB is never modified, so every shot list (`load_recent_shots`, `load_recent_shots_paged`) now scans a generous buffer of SDB rows and filters out any filename present in the trash manifest before slicing to the requested page, so deleted shots disappear immediately even though their SDB rows still exist. "Showing X-Y of N shots" now reports the filtered total (`_visible_shot_count`), and Advanced/Diagnostics show "N deleted shot(s) hidden (SDB not modified; it may resync on its own)."
- **Restore:** a new Advanced > Trash / Restore page lists every trash batch (date, shot count, file count) with a Restore button per batch. Restore moves files back to their original paths (move only) and drops them from the manifest; if a file already exists at the original path, that one file is left in the trash/manifest as a collision instead of being overwritten, so it can be retried later. No "Empty trash" button exists -- permanent deletion is not implemented.
- Reused the CLAUDE.md design system exactly for every new page (Review, Confirm, Result, Trash/Restore): same tokens, `font_button`, virtual-coordinate basis, label/value grid, and standard button rows as the rest of the plugin.
- Safety status: grepped the whole plugin for INSERT/UPDATE/DELETE/ALTER/DROP/CREATE TABLE/VACUUM/REINDEX (none) and for `file delete` (none -- only `file rename` for moves, and `file open ... w`/`a` on the plugin's own `trash_manifest.txt`/`delete_log.txt`, never on history file content). Verified with a headless sandbox test: delete moves the right files, cancel at either step performs zero file operations, restore round-trips correctly (including a simulated name-collision case), and an unsafe/path-traversal-style filename is rejected before any file operation.

## v0.3.3 - Pass 3.3 Button Font Bugfix

Button font fix only, still no write/delete behavior.

- **Fix:** all button label text (Select, Prev, Next, Edit, Done, Advanced, Cancel, OK, Clear Selection, Next Field, Preview Change, Back, Diagnostics, Help / Guide, Source Inspector, and every card/bar/toolbar button on every page) rendered noticeably smaller than the design-system button size after v0.3.2. Root cause: button labels are created through a different dui code path than card text (`dui add dbutton`'s internal label rendering vs. our own raw `-font` on `dui add dtext`). v0.3.2 tried to size button labels via `dui aspect set -type dbutton_label -style she_btn {font_size ...}`, assuming that aspect key would be rescaled by dui the same way `bwidth`/`bheight`/`radius` are -- it was not honored by the framework on the tablet, so buttons fell back to a small skin default.
- Fixed by adding a single `font_button` Tk font object to the layout block (20px bold equivalent, same `font_scale` basis as `font_primary` and the other card-text fonts -- i.e. sized for the real physical screen, not the virtual coordinate space), and passing it directly via `-label_font $L(font_button)` on all 32 `dui add dbutton` calls across every page (a per-instance override confirmed to work in `plugins/visualizer_upload/plugin.tcl:467,505-507`). The non-functional `dbutton_label` aspect font_size key and the old `btn_px` virtual-scale variable were removed; the `dbutton` aspect style keeps only `shape round radius ...`, which was already working correctly.
- Verified no other change was needed for centering: no `-label_pos`/`-label_justify`/`-label_width` overrides were touched, so default button-label centering is unaffected. Checked "Clear Selection" (selection mode's longest label, drawn in the main page's `bar_right` slot at `btn_w_std` width) against the new 20px bold font: at the reference resolution the label comfortably fits with room to spare.
- No layout coordinates, plugin logic, SDB reading, or navigation changed from v0.3.2; only `_init_layout`'s font block and each `dui add dbutton` call's arguments changed.

## v0.3.2 - Pass 3.2 Coordinate-Basis Bugfix

Coordinate-basis fix only, still no write/delete behavior.

- **Fix (critical):** v0.3.1 rendered the entire UI at roughly half size in the top-left quadrant of the screen, with overlapping card text. Root cause: DE1app `fpdialog` pages are drawn in a fixed VIRTUAL coordinate space (~2560x1600, inferred from SDB.tcl centering titles at x=1280 and GrindAdvisor.tcl placing buttons up to y~1580-1600) that dui itself rescales to the real physical screen (confirmed by the one dui coordinate-rescale API found in this workspace, `dui::platform::rescale_x`/`rescale_y` in plugins/visualizer_upload/plugin.tcl). v0.3.1 computed every coordinate from `winfo screenwidth/screenheight` (the real physical size, e.g. 1340x800) instead of that virtual space, so dui rescaled our already-physical-sized coordinates a second time (~0.52x), shrinking and repositioning everything toward the top-left. Meanwhile our custom Tk fonts (`font create ... -size -N`) are plain font objects referenced by name -- dui has no way to rescale them, so they stayed at their original (correct-for-physical) size and no longer fit the doubly-shrunk card spacing, causing the baseline collisions.
- Fixed by using two independent scale factors: `scale` (coordinates) is now derived from a fixed virtual base resolution constant (2560x1600), while `font_scale` (our own Tk font pixel sizes) is derived from the real detected physical screen via `winfo`, exactly as before. Every v0.3.1 token formula, ratio, and layout rule is otherwise byte-for-byte unchanged -- only the input driving `scale` changed. The one exception is `btn_px` (feeds `dui aspect set -type dbutton_label`, part of dui's own button-rendering pipeline alongside virtual-space `bwidth`/`bheight`), which correctly stays on the virtual `scale`, not `font_scale`.
- Verified by recomputing the reference render: content width now spans the full screen minus margins (previously about half), the bottom bar lands ~50px above the physical bottom edge (previously far short of it), and the three card text baselines (+30/+56/+80 reference units) no longer collide once rescaled back to physical pixels.
- No plugin logic, SDB reading, navigation, or input-handling changes from v0.3.1; only `_init_layout`'s coordinate-basis and font-scale source changed.
- Safety status: no INSERT/UPDATE/DELETE/ALTER/DROP/CREATE TABLE/VACUUM/REINDEX, no file delete/rename/move/copy calls anywhere in the plugin. Delete remains preview-only.

## v0.3.1 - Pass 3.1 Input Fix + UI Precision Pass

Input fix + layout system only, still no write/delete behavior.

- **Fix (critical):** selection mode had no working buttons on the tablet (Cancel/Delete/Clear Selection/cards/Prev/Next all unresponsive). Root cause: v0.3.0 stacked multiple full-size interactive buttons at identical coordinates (Select/Cancel, Advanced/Delete, Done/Clear Selection, and 3 buttons per card row) and toggled which one was visible with `dui item show/hide`; once more than one interactive widget shares a bounding box, tap routing on this page system becomes ambiguous and none of them respond reliably. Fixed by giving every slot exactly one button with a stable command dispatcher (reads mode at click time) and a dynamically-reconfigured caption; no two widgets ever share a rectangle again. Cancel and Done/Back are now unconditionally reachable, and entering the main page always resets selection-mode state defensively.
- Replaced fixed/guessed coordinates with a design-token layout system computed from the real detected screen size (`winfo screenwidth/screenheight`, matching the pattern GrindAdvisor already uses for its own popups): spacing tokens (xs/sm/md/lg/xl/xxl), margins, card and button dimensions, header/toolbar/list/bottom-bar zones, and five fixed pixel font sizes (title/section/primary/body/caption), all scaled from `screen_h/800` with sensible floors.
- Added a reusable `rounded_rect` helper (smoothed-polygon technique) used for all card backgrounds.
- Main page card list reduced to 5 cards per page (required for correct spacing at the new card height); Prev/Next moved from the bottom to a toolbar row under the header, now showing "Showing X-Y of N shots."
- Applied the same token system to every page: Advanced / Source Inspector, Delete Preview, Source Inspector picker, Shot Detail, Edit Metadata Preview (labels at a fixed label column, values at a fixed value column), Diagnostics, and Help.
- No plugin logic, SDB reading, or delete/save behavior changed; `load_recent_shots`, `read_legacy_settings`, `read_history_v2_meta`, and the paged-text logic for Detail/Diagnostics/Help are untouched.
- Safety status: no INSERT/UPDATE/DELETE/ALTER/DROP/CREATE TABLE/VACUUM/REINDEX, no file delete/rename/move/copy calls anywhere in the plugin. Delete remains preview-only.

## v0.3.0 - Pass 3 One-Page Workflow Redesign

- Replaced the menu-first main page with a card-based main page that opens directly to recent shot cards (no button step).
- Each card shows date/time, shot time, grind, dose, yield, bean/profile, and an Edit (✎) button that opens the existing Edit Metadata Preview page.
- Added Select/Cancel selection mode: a Select button on each card, a bottom action bar with Delete and Clear Selection.
- Delete opens a "Delete Preview" screen showing the count of selected shots and the notice "No files will be modified in this version." Cancel and OK both simply close the preview.
- Moved Shot Detail (source comparison), Diagnostics, and Help / Guide behind a single new Advanced / Source Inspector page; the normal workflow no longer requires entering Advanced.
- Added Prev/Next paging for the card list (offset-based, reusing the existing read-only SDB query pattern).
- Reused the existing v0.2.0 data-reading, legacy `.shot`/`history_v2` parsing, and Edit Metadata Preview logic unchanged.
- Card and button layout is derived from a small set of layout constants against the plugin's existing virtual dui canvas (the same fixed-coordinate convention already used by v0.2.0 and by the SDB plugin, which the app's own dui/skin engine scales to the physical screen) instead of scattered hardcoded coordinates.
- Safety status: no INSERT/UPDATE/DELETE/ALTER/DROP/CREATE TABLE/VACUUM/REINDEX added, no file delete/rename/move calls added, no write behavior exists in this version. Delete is preview-only and does not touch SDB, `history/*.shot`, or `history_v2/*.json`. Raw pressure/flow/temperature/chart/sensor data is still never displayed or edited.

## v0.2.0 - Pass 2 Edit Preview + Scrollable Detail Pages

- Added paged scrolling controls for Shot Detail, Diagnostics, and Help / Guide.
- Added Edit Metadata Preview page from Shot Detail.
- Added safe field selection for legacy `history/*.shot` settings metadata.
- Added current value, new value, before/after preview, and numeric warnings.
- Added diagnostics for scrolling support and selected-shot source matching.
- Kept all runtime data access read-only with no save button, no shot hooks, and no after-shot popups.

## v0.1.0 - Pass 1 Read-only Source Inspector

- Added initial ShotHistoryEditor plugin shell.
- Added read-only SDB browsing from `plugins/SDB/shots.db`.
- Added recent-shot list, detail comparison, diagnostics, and help pages.
- Added legacy `history/*.shot` settings-block inspection.
- Added `history_v2/*.json` meta-block inspection.
- Kept runtime behavior read-only with no edit controls, save buttons, shot hooks, or after-shot popups.
