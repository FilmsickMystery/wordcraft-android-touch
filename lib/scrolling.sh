#!/usr/bin/env bash
# Android touch interaction — app-side patches.
#
# The Android backend forwards touchscreen contacts as native touch events. egui owns pinch
# recognition; these patches keep multi-touch from turning into text selection or canvas focus.
#
# The app also supplies momentum for smooth scroll input on Android, which does not provide
# its own coast for the app's wheel-based scrolling.
#
# Every edit is guarded and idempotent: it applies only while the original text is still
# present, so it no-ops once upstream handles it, and is re-applied on a fresh checkout.
#
# To test without the app-side patches, comment out the call to this script in
# lib/build-common.sh.
#
# Usage: scrolling.sh <source-dir> <app> <title>
set -euo pipefail

SRC="${1:?source dir}"
APP="${2:?app}"
TITLE="${3:?title}"

python3 - "$SRC" "$APP" "$TITLE" <<'PY'
from pathlib import Path
import re
import sys

src, app, title = Path(sys.argv[1]), sys.argv[2], sys.argv[3]


def fix(rel: str, old: str, new: str) -> bool:
    """Replace the single `old` in `rel` with `new`, unless it is already gone or already fixed."""
    path = src / rel
    try:
        text = path.read_text()
    except OSError:
        return False
    if old not in text or new in text or text.count(old) != 1:
        return False
    path.write_text(text.replace(old, new, 1))
    return True


def sub(rel: str, pattern: str, new: str) -> bool:
    """Replace the first match of `pattern` in `rel` with `new`, unless it is already fixed."""
    path = src / rel
    try:
        text = path.read_text()
    except OSError:
        return False
    if new in text:
        return False
    updated, count = re.subn(pattern, new, text, count=1, flags=re.S)
    if count != 1:
        return False
    path.write_text(updated)
    return True


def rewrite(rel: str, old: str, new: str) -> bool:
    """Replace matching legacy patch text without requiring an unmodified source anchor."""
    path = src / rel
    try:
        text = path.read_text()
    except OSError:
        return False
    if old not in text:
        return False
    path.write_text(text.replace(old, new))
    return True


def upgrade(rel: str, old: str, new: str) -> bool:
    """Upgrade one prior builder insertion, while leaving its current form unchanged."""
    path = src / rel
    try:
        text = path.read_text()
    except OSError:
        return False
    if old not in text or new in text:
        return False
    path.write_text(text.replace(old, new, 1))
    return True


fixed = []
if app == "wordcraft":
    # Older builds surrendered canvas focus and hid the IME during scrolling/drawing. Remove
    # those generated source edits as well as no longer adding them below; checkouts are reused.
    canvas_path = src / "crates/ui-egui/src/canvas.rs"
    try:
        canvas_text = canvas_path.read_text()
    except OSError:
        canvas_text = ""
    canvas_text, removed = re.subn(
        r"        // On Android: if there's an active touch scroll/drag \(not text selection\),\n"
        r".*?        }\n",
        "",
        canvas_text,
        count=1,
        flags=re.S,
    )
    if removed:
        canvas_path.write_text(canvas_text)
        fixed.append("crates/ui-egui/src/canvas.rs (removed forced keyboard dismissal)")
    for rel, old, new in (
        (
            "crates/ui-egui/src/canvas.rs",
            "    /// Set when focus is surrendered this frame to suppress IME output immediately.\n"
            "    pub surrendered_focus: bool,\n",
            "",
        ),
        ("crates/ui-egui/src/canvas.rs", "            surrendered_focus: false,\n", ""),
        ("crates/ui-egui/src/canvas.rs", "    app.canvas.surrendered_focus = false; // reset each frame\n", ""),
        (
            "crates/ui-egui/src/canvas.rs",
            "    /// The canvas was explicitly focused by a user tap — used to suppress auto-focus on load.\n"
            "    pub user_focused: bool,\n",
            "",
        ),
        ("crates/ui-egui/src/canvas.rs", "            user_focused: false,\n", ""),
        ("crates/ui-egui/src/canvas.rs", "    app.canvas.user_focused = true;\n", ""),
        ("crates/ui-egui/src/canvas.rs", "if has_text_caret && !app.canvas.surrendered_focus {", "if has_text_caret {"),
        (
            "crates/ui-egui/src/canvas.rs",
            "let shown = app.session.sel.is_collapsed() && focused && !app.canvas.surrendered_focus;",
            "let shown = app.session.sel.is_collapsed() && focused;",
        ),
        (
            "crates/ui-egui/src/lib.rs",
            "    /// Set by the canvas on Android when a scroll or a draw surrenders the keyboard, so\n"
            "    /// the shell can put it away at once (see the shell's `logic`).\n"
            "    pub request_ime_hide: bool,\n",
            "",
        ),
        ("crates/ui-egui/src/lib.rs", "            request_ime_hide: false,\n", ""),
    ):
        if rewrite(rel, old, new):
            fixed.append(f"{rel} (removed forced keyboard dismissal)")

    canvas_path = src / "crates/ui-egui/src/canvas.rs"
    try:
        canvas_text = canvas_path.read_text()
    except OSError:
        canvas_text = ""
    canvas_text, removed = re.subn(
        r"    // If the canvas somehow got focus without a user action \(e\.g\. initial frame\),\n"
        r"    // surrender it so the soft keyboard doesn't appear prematurely\.\n"
        r"    let initial_surrender = !app\.canvas\.user_focused && resp\.has_focus\(\);\n"
        r"    if initial_surrender \{\n"
        r"        resp\.surrender_focus\(\);\n"
        r"    \}\n",
        "",
        canvas_text,
        count=1,
    )
    if removed:
        canvas_path.write_text(canvas_text)
        fixed.append("crates/ui-egui/src/canvas.rs (removed initial focus surrender)")

    # egui recognizes native multi-touch from the forwarded touch events. Keep those frames
    # from becoming canvas clicks, focus changes, or text-selection drags.
    guard = (
        "/// A two-finger gesture (scroll or pinch) is in progress: a touch press during it is part\n"
        "/// of that gesture, not a click, and any text-selection drag it began must be dropped.\n"
        "fn touch_gesture_active(ui: &egui::Ui) -> bool {\n"
        "    ui.input(|i| {\n"
        "        i.events\n"
        "            .iter()\n"
        "            .any(|e| matches!(e, egui::Event::Touch { phase: egui::TouchPhase::Cancel, .. }))\n"
        "            || (cfg!(target_os = \"android\") && i.multi_touch().is_some())\n"
        "            || (cfg!(target_os = \"android\") && i.events.iter().any(|e| matches!(e,\n"
        "                egui::Event::MouseWheel { unit: egui::MouseWheelUnit::Point, .. }\n"
        "                    | egui::Event::Zoom(_)\n"
        "            )))\n"
        "    })\n"
        "}\n"
    )
    # Older upstream revisions used a `mouse` helper, but 0.12.0 renamed it and no longer
    # has a stable insertion point. Append the helper at module scope instead of relying on
    # an implementation-specific function signature.
    canvas_path = src / "crates/ui-egui/src/canvas.rs"
    canvas_text = canvas_path.read_text()
    if "fn touch_gesture_active(" not in canvas_text:
        canvas_path.write_text(canvas_text.rstrip() + "\n\n" + guard + "\n")
        fixed.append("crates/ui-egui/src/canvas.rs (touch gestures start no selection)")
    elif sub(
        "crates/ui-egui/src/canvas.rs",
        r"/// A two-finger gesture \(scroll or pinch\) is in progress.*?\nfn touch_gesture_active\(ui: &egui::Ui\) -> bool \{\n.*?\n\}\n",
        guard,
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (touch gestures start no selection)")

    # Do not begin or continue a selection during a native multi-touch gesture.
    if fix(
        "crates/ui-egui/src/canvas.rs",
        "    let pressed = ui.input(|i| i.pointer.primary_pressed()) && resp.contains_pointer() && !over_balloon(app, p);\n",
        "    let pressed = ui.input(|i| i.pointer.primary_pressed())\n"
        "        && !touch_gesture_active(ui)\n"
        "        && !android_pointer_over_overlay(ui)\n"
        "        && resp.contains_pointer()\n"
        "        && !over_balloon(app, p);\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (gestures do not select text)")
    elif fix(
        "crates/ui-egui/src/canvas.rs",
        "    let pressed = ui.input(|i| i.pointer.primary_pressed())\n"
        "        && !touch_gesture_active(ui)\n"
        "        && resp.contains_pointer()\n"
        "        && !over_balloon(app, p);\n",
        "    let pressed = ui.input(|i| i.pointer.primary_pressed())\n"
        "        && !touch_gesture_active(ui)\n"
        "        && !android_pointer_over_overlay(ui)\n"
        "        && resp.contains_pointer()\n"
        "        && !over_balloon(app, p);\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (multitouch does not select text)")
    elif upgrade(
        "crates/ui-egui/src/canvas.rs",
        "    let pressed = ui.input(|i| i.pointer.primary_pressed())\n"
        "        && !touch_gesture_active(ui)\n"
        "        && !android_pointer_over_overlay(ui)\n"
        "        && resp.contains_pointer()\n"
        "        && !over_balloon(app, p);\n",
        "    let pressed = ui.input(|i| i.pointer.primary_pressed())\n"
        "        && !touch_gesture_active(ui)\n"
        "        && !android_pointer_over_overlay(ui)\n"
        "        && resp.contains_pointer()\n"
        "        && !over_balloon(app, p);\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (overlay taps do not select document text)")

    # A second finger arriving after the press already started a drag: drop the selection.
    # Runs before the drag-extension arms below.
    if fix(
        "crates/ui-egui/src/canvas.rs",
        "    } else if app.canvas.dragging\n"
        "        && ui.input(|i| i.pointer.primary_down())\n"
        "        && let Some(d) = app.canvas.unit_drag.as_mut()\n",
        "    } else if app.canvas.dragging\n"
        "        && touch_gesture_active(ui)\n"
        "    {\n"
        "        // A gesture took over: stop selecting and forget the drag.\n"
        "        app.canvas.cancel_text_drag();\n"
        "    } else if app.canvas.dragging\n"
        "        && ui.input(|i| i.pointer.primary_down())\n"
        "        && let Some(d) = app.canvas.unit_drag.as_mut()\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (scroll cancels a live selection drag)")
    elif upgrade(
        "crates/ui-egui/src/canvas.rs",
        "    } else if app.canvas.dragging && touch_gesture_active(ui) {\n"
        "        // A two-finger scroll took over: stop selecting and forget the drag.\n"
        "        app.canvas.cancel_text_drag();\n",
        "    } else if app.canvas.dragging\n"
        "        && touch_gesture_active(ui)\n"
        "    {\n"
        "        // A gesture took over: stop selecting and forget the drag.\n"
        "        app.canvas.cancel_text_drag();\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (multitouch cancels text selection)")

    canvas_path = src / "crates/ui-egui/src/canvas.rs"
    try:
        canvas_text = canvas_path.read_text()
    except OSError:
        canvas_text = ""
    if canvas_text:
        original_canvas_text = canvas_text
        canvas_text = re.sub(
            r"\n#\[derive\(Clone, Copy\)\]\nstruct AndroidBlankPan \{.*?"
            r"fn android_blank_touch_pan_active\(ctx: &egui::Context\) -> bool \{\n.*?\n\}\n?",
            "\n",
            canvas_text,
            count=1,
            flags=re.S,
        )
        canvas_text = re.sub(
            r"    let blank_touch_delta = if !app\.session\.view\.read_mode \{\n"
            r"        android_blank_touch_scroll\(ui, full, &app\.canvas\.page_rects\)\n"
            r"    \} else \{\n"
            r"        egui::Vec2::ZERO\n"
            r"    \};\n"
            r"    let wheel_delta = wheel_delta \+ blank_touch_delta;\n",
            "",
            canvas_text,
            count=1,
        )
        canvas_text = canvas_text.replace(
            "        && !android_blank_touch_pan_active(ui.ctx())\n", ""
        )
        canvas_text = canvas_text.replace(
            "        && (touch_gesture_active(ui) || android_blank_touch_pan_active(ui.ctx()))\n",
            "        && touch_gesture_active(ui)\n",
        )
        if canvas_text != original_canvas_text:
            canvas_path.write_text(canvas_text)
            fixed.append("crates/ui-egui/src/canvas.rs (remove blank-area touch panning)")
    overlay_guard = (
        "fn android_pointer_over_overlay(ui: &egui::Ui) -> bool {\n"
        "    ui.input(|input| input.pointer.interact_pos())\n"
        "        .and_then(|pos| ui.ctx().layer_id_at(pos))\n"
        "        .is_some_and(|layer| layer != ui.layer_id())\n"
        "}\n"
    )
    if canvas_text and "fn android_pointer_over_overlay(" not in canvas_text:
        canvas_path.write_text(canvas_text.rstrip() + "\n\n" + overlay_guard)
        fixed.append("crates/ui-egui/src/canvas.rs (preserve overlay input guard)")

    # Undo the prior builder's keyboard-docked toolbar patch in reused source checkouts.
    toolbar_anchor = "    let Some(bar) = anchor_rect(selection.min.y, selection.min.x, viewport) else { return };\n"
    if sub(
        "crates/ui-egui/src/mini_toolbar.rs",
        r"    let ime_bottom = if cfg!\(target_os = \"android\"\) \{\n.*?    \};\n",
        toolbar_anchor,
    ):
        fixed.append("crates/ui-egui/src/mini_toolbar.rs (restore selection-anchored toolbar)")
    for old, new in (
        (
            "    let shown = bar.intersect(toolbar_viewport);\n",
            "    let shown = bar.intersect(viewport);\n",
        ),
        (
            "    let area = area.constrain_to(toolbar_viewport).constrain(false).fixed_pos(bar.min);\n",
            "    let area = area.constrain_to(viewport).constrain(false).fixed_pos(bar.min);\n",
        ),
    ):
        if rewrite("crates/ui-egui/src/mini_toolbar.rs", old, new):
            fixed.append("crates/ui-egui/src/mini_toolbar.rs (restore viewport clipping)")

    # Do not raise the keyboard automatically on the first frame.
    if fix(
        "crates/ui-egui/src/canvas.rs",
        "            want_focus: true,\n",
        "            want_focus: false,\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (no keyboard before the first tap)")

    # Keep emitting IME output while a canvas remains focused, even when its selection is a
    # range. Omitting it during a drag tells egui-winit to hide the keyboard; restoring it on
    # the next frame calls showSoftInput again and makes Gboard flicker.
    if sub(
        "crates/ui-egui/src/canvas.rs",
        r"                // A real text caret \(a collapsed selection\), not just canvas focus\.\n"
        r"                let has_text_caret = app\.session\.sel\.is_collapsed\(\) && focused;\n"
        r"                if has_text_caret \{\n"
        r".*?"
        r"                \}\n",
        "                if focused {\n"
        "                    ui.ctx().request_repaint_after(std::time::Duration::from_millis(530 - (since as u64 % 530)));\n"
        "                    let cr = Rect::from_min_max(pos2(x, y0), pos2(x + 1.0, y1));\n"
        "                    ui.ctx().output_mut(|o| {\n"
        "                        o.ime = Some(egui::output::IMEOutput {\n"
        "                            rect: cr,\n"
        "                            cursor_rect: cr,\n"
        "                            purpose: Default::default(),\n"
        "                            should_interrupt_composition: ime_reset,\n"
        "                        });\n"
        "                    });\n"
        "                }\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (keep IME active during text selection)")

    # Undo the prior builder's selection-collapsed IME candidate guard in reused checkouts.
    if sub(
        "crates/ui-egui/src/canvas.rs",
        r"            // IME candidate window placement\.\n"
        r"            let cr = Rect::from_min_max\(pos2\(x, y0\), pos2\(x \+ 1\.0, y1\)\);\n"
        r"            if shown \{\n",
        "            // IME candidate window placement.\n"
        "            let cr = Rect::from_min_max(pos2(x, y0), pos2(x + 1.0, y1));\n"
        "            if focused {\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (keep IME active for non-collapsed selection)")

    # The canvas owns IME focus only for taps on a page. A drag on touch must not focus
    # immediately: the second finger may turn it into a pinch after the first frame.
    focus_block = (
        "    let pointer_click = resp.clicked_by(egui::PointerButton::Primary);\n"
        "    let accesskit_click = resp.clicked() && !pointer_click && !keyboard_click;\n"
        "    let pointer_pos = ui.input(|i| i.pointer.interact_pos());\n"
        "    let page_tap = pointer_pos.is_some_and(|pos| {\n"
        "        app.canvas.page_rects.iter().any(|page| page.contains(pos))\n"
        "            && ui.ctx().layer_id_at(pos).is_some_and(|layer| layer == resp.layer_id)\n"
        "    });\n"
        "    let touch_event = ui.input(|i| i.events.iter().any(|event| matches!(event, egui::Event::Touch { .. })));\n"
        "    let drag_focus = !touch_event && resp.drag_started() && page_tap;\n"
        "    let focus_click = !crate::canvas::touch_gesture_active(ui)\n"
        "        && ((pointer_click && page_tap) || drag_focus || accesskit_click);\n"
        "    if focus_click {\n"
    )
    if sub(
        "crates/ui-egui/src/canvas.rs",
        r"    let pointer_click = resp\.clicked_by\(egui::PointerButton::Primary\);\n"
        r"    let accesskit_click = resp\.clicked\(\) && !pointer_click && !keyboard_click;\n"
        r".*?    if focus_click \{\n",
        focus_block,
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (focus only for page editing)")


    # The flick's coast. The upstream constant leaves the momentum to the platform on the
    # platforms that send their own: macOS and Windows (they report the lift, and a touchpad
    # there as line deltas) and the web (Chromium synthesises the coast and sends it as more
    # wheel events, which is why the web build must not make one as well).
    #
    # Android sends no momentum of its own for smooth scroll input, so the app has to make
    # the coast, exactly as it does on Linux. The earlier builder patch excluded Android,
    # which left a flick with no coast at all.
    #
    # A mouse's notches are line deltas and never reach the momentum, so they cannot coast:
    # only the smooth (point) deltas of a pan or a trackpad do.
    without_android = (
        "const SYNTH_MOMENTUM: bool = !cfg!(any(\n"
        '    target_os = "macos",\n'
        '    target_os = "ios",\n'
        '    target_os = "windows",\n'
        '    target_arch = "wasm32",\n'
        "));"
    )
    if fix(
        "crates/ui-egui/src/scroll.rs",
        'const SYNTH_MOMENTUM: bool = !cfg!(any(target_os = "macos", target_os = "ios", target_os = "windows", target_arch = "wasm32"));',
        without_android,
    ):
        fixed.append("crates/ui-egui/src/scroll.rs (the app makes the coast Android does not send)")
    elif sub(
        "crates/ui-egui/src/scroll.rs",
        r"const SYNTH_MOMENTUM: bool = !cfg!\(any\(.*?\n\)\);",
        without_android,
    ):
        fixed.append("crates/ui-egui/src/scroll.rs (the app makes the coast Android does not send)")

    # Publish WordCraft's committed text window, native selection, and UTF-8 cursor offsets for
    # the generated Android IME host, which converts these offsets to UTF-16 for Gboard.
    if fix(
        "crates/ui-egui/src/keys/ime.rs",
        "    let focused = app.canvas.focused && geometry.is_some();\n"
        "    let update = if focused {\n",
        "    let focused = app.canvas.focused && geometry.is_some();\n"
        "    let window = if focused && app.session.math.is_none() {\n"
        "        ime_window(app)\n"
        "    } else {\n"
        "        None\n"
        "    };\n"
        "    ctx.data_mut(|data| {\n"
        "        data.insert_temp(\n"
        "            egui::Id::new(\"artcraft_android_ime_state\"),\n"
        "            window.as_ref().map(|w| (w.text.clone(), w.cursor, w.anchor)),\n"
        "        );\n"
        "    });\n"
        "    let update = if focused {\n",
    ):
        fixed.append("crates/ui-egui/src/keys/ime.rs (publish committed IME state to Android)")
    if fix(
        "crates/ui-egui/src/keys/ime.rs",
        "            window.as_ref().map(|w| (w.text.clone(), w.cursor, w.anchor)),\n"
        "        );\n"
        "    });\n"
        "    let update = if focused {\n",
        "            window.as_ref().map(|w| (w.text.clone(), w.cursor, w.anchor)),\n"
        "        );\n"
        "    });\n"
        "    let selected_text = app.session.selected_text();\n"
        "    let selected_text = if selected_text.is_empty() {\n"
        "        None\n"
        "    } else {\n"
        "        Some(selected_text)\n"
        "    };\n"
        "    ctx.data_mut(|data| {\n"
        "        data.insert_temp(\n"
        "            egui::Id::new(\"artcraft_android_selected_text\"),\n"
        "            selected_text,\n"
        "        );\n"
        "    });\n"
        "    let update = if focused {\n",
    ):
        fixed.append("crates/ui-egui/src/keys/ime.rs (publish selected document text for Android copy)")
    if fix(
        "crates/ui-egui/src/keys/ime.rs",
        "            let window = ime_window(app);\n",
        "            let window = window.clone();\n",
    ):
        fixed.append("crates/ui-egui/src/keys/ime.rs (reuse the published IME text window)")

if fixed:
    print(f"  Added two-finger-scroll patches to {title}: {', '.join(fixed)}")
PY
