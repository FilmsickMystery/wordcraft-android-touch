#!/usr/bin/env bash
# Two-finger scrolling — the app-side patches.
#
# A phone or tablet has no wheel, so a two-finger drag is the only way to scroll. The
# builder's vendored winit backend (see lib/build-common.sh) recognises the gesture the way
# a browser does — a two-finger slide scrolls, a two-finger pinch zooms — and takes it over
# from the touch path: the fingers' touches are withheld, and the first finger's touch is
# cancelled so the gesture cannot start a text selection.
#
# Two things are left for the app:
#
#  * the press that arrives with the *first* finger must not start a selection: the canvas
#    has to know a gesture is in progress, which it learns from the touch the backend
#    cancelled;
#  * the momentum. The web build leaves the flick's coast to the browser (Chromium
#    synthesises it and sends it as more wheel events), and so do macOS and Windows; Android
#    sends no momentum of its own for a two-finger pan, so the app has to make the coast
#    itself, exactly as it does on Linux.
#
# Every edit is guarded and idempotent: it applies only while the original text is still
# present, so it no-ops once upstream handles it, and is re-applied on a fresh checkout.
#
# The scroll synthesis itself (the vendored winit/egui-winit backends) lives in
# lib/build-common.sh and runs regardless of this script; this script adds the app side.
#
# To test WITHOUT the patches, comment out the call to this script in lib/build-common.sh.
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

    # Android reports two-finger pans as point-wheel events and pinches as zoom events after
    # taking their touches over. Keep treating those frames as gestures, not clicks or focus
    # changes; the initial cancelled touch covers the hand-off frame.
    guard = (
        "/// A two-finger gesture (scroll or pinch) is in progress: a touch press during it is part\n"
        "/// of that gesture, not a click, and any text-selection drag it began must be dropped.\n"
        "fn touch_gesture_active(ui: &egui::Ui) -> bool {\n"
        "    ui.input(|i| {\n"
        "        i.events\n"
        "            .iter()\n"
        "            .any(|e| matches!(e, egui::Event::Touch { phase: egui::TouchPhase::Cancel, .. }))\n"
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

    # Do not begin a selection on a press that is part of a gesture or blank-area pan.
    if fix(
        "crates/ui-egui/src/canvas.rs",
        "    let pressed = ui.input(|i| i.pointer.primary_pressed()) && resp.contains_pointer() && !over_balloon(app, p);\n",
        "    let pressed = ui.input(|i| i.pointer.primary_pressed())\n"
        "        && !touch_gesture_active(ui)\n"
        "        && !android_blank_touch_pan_active(ui.ctx())\n"
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
        "        && !android_blank_touch_pan_active(ui.ctx())\n"
        "        && !android_pointer_over_overlay(ui)\n"
        "        && resp.contains_pointer()\n"
        "        && !over_balloon(app, p);\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (blank pans do not select text)")
    elif upgrade(
        "crates/ui-egui/src/canvas.rs",
        "    let pressed = ui.input(|i| i.pointer.primary_pressed())\n"
        "        && !touch_gesture_active(ui)\n"
        "        && !android_blank_touch_pan_active(ui.ctx())\n"
        "        && resp.contains_pointer()\n"
        "        && !over_balloon(app, p);\n",
        "    let pressed = ui.input(|i| i.pointer.primary_pressed())\n"
        "        && !touch_gesture_active(ui)\n"
        "        && !android_blank_touch_pan_active(ui.ctx())\n"
        "        && !android_pointer_over_overlay(ui)\n"
        "        && resp.contains_pointer()\n"
        "        && !over_balloon(app, p);\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (overlay taps do not select document text)")

    # A second finger arriving after the press already started a drag: drop it, so the scroll
    # never carries a selection along. Runs before the drag-extension arms below.
    if fix(
        "crates/ui-egui/src/canvas.rs",
        "    } else if app.canvas.dragging\n"
        "        && ui.input(|i| i.pointer.primary_down())\n"
        "        && let Some(d) = app.canvas.unit_drag.as_mut()\n",
        "    } else if app.canvas.dragging\n"
        "        && (touch_gesture_active(ui) || android_blank_touch_pan_active(ui.ctx()))\n"
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
        "        && (touch_gesture_active(ui) || android_blank_touch_pan_active(ui.ctx()))\n"
        "    {\n"
        "        // A gesture took over: stop selecting and forget the drag.\n"
        "        app.canvas.cancel_text_drag();\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (blank pans cancel text selection)")

    # A one-finger drag that starts in blank canvas space is a pan, not a caret selection.
    # Only claim it when the point is not handled by a widget or an overlay layer.
    blank_pan_state = (
        "#[derive(Clone, Copy)]\n"
        "struct AndroidBlankPan { id: egui::TouchId, last: egui::Pos2, ending: bool }\n"
    )
    blank_pan_scroll = (
        "fn android_blank_touch_scroll(ui: &egui::Ui, full: egui::Rect, pages: &[egui::Rect]) -> egui::Vec2 {\n"
        "    if !cfg!(target_os = \"android\") {\n"
        "        return egui::Vec2::ZERO;\n"
        "    }\n"
        "    let touches = ui.input(|input| {\n"
        "        input.events.iter().filter_map(|event| match event {\n"
        "            egui::Event::Touch { id, phase, pos, .. } => Some((*id, *phase, *pos)),\n"
        "            _ => None,\n"
        "        }).collect::<Vec<_>>()\n"
        "    });\n"
        "    let ctx = ui.ctx();\n"
        "    let state_id = egui::Id::new(\"wordcraft_android_blank_pan\");\n"
        "    let mut pan = ctx.data(|data| data.get_temp::<AndroidBlankPan>(state_id));\n"
        "    let gesture_active = touch_gesture_active(ui);\n"
        "    if gesture_active { pan = None; }\n"
        "    if touches.is_empty() && pan.is_some_and(|active| active.ending) { pan = None; }\n"
        "    let mut delta = egui::Vec2::ZERO;\n"
        "    let mut block_new_pan = gesture_active;\n"
        "    for (id, phase, pos) in touches {\n"
        "        match phase {\n"
        "            egui::TouchPhase::Start => {\n"
        "                if pan.is_some() { pan = None; block_new_pan = true; }\n"
        "                        let over_ui = ctx.egui_is_using_pointer()\n"
        "                    || ctx.layer_id_at(pos).is_some_and(|layer| layer != ui.layer_id());\n"
        "                pan = (!block_new_pan && !over_ui && full.contains(pos)\n"
        "                    && !pages.iter().any(|page| page.contains(pos)))\n"
        "                    .then_some(AndroidBlankPan { id, last: pos, ending: false });\n"
        "            }\n"
        "            egui::TouchPhase::Move => {\n"
        "                if let Some(active) = pan.as_mut().filter(|active| active.id == id) {\n"
        "                    delta += active.last - pos;\n"
        "                    active.last = pos;\n"
        "                    active.ending = false;\n"
        "                }\n"
        "            }\n"
        "            egui::TouchPhase::End | egui::TouchPhase::Cancel => {\n"
        "                if let Some(active) = pan.as_mut().filter(|active| active.id == id) {\n"
        "                    active.ending = true;\n"
        "                }\n"
        "            }\n"
        "        }\n"
        "    }\n"
        "    ctx.data_mut(|data| {\n"
        "        if let Some(active) = pan { data.insert_temp(state_id, active); }\n"
        "        else { data.remove::<AndroidBlankPan>(state_id); }\n"
        "    });\n"
        "    delta\n"
        "}\n"
    )
    blank_pan_active = (
        "fn android_blank_touch_pan_active(ctx: &egui::Context) -> bool {\n"
        "    cfg!(target_os = \"android\") && ctx.data(|data| {\n"
        "        data.get_temp::<AndroidBlankPan>(egui::Id::new(\"wordcraft_android_blank_pan\")).is_some()\n"
        "    })\n"
        "}\n"
    )
    overlay_guard = (
        "fn android_pointer_over_overlay(ui: &egui::Ui) -> bool {\n"
        "    ui.input(|input| input.pointer.interact_pos())\n"
        "        .and_then(|pos| ui.ctx().layer_id_at(pos))\n"
        "        .is_some_and(|layer| layer != ui.layer_id())\n"
        "}\n"
    )

    canvas_path = src / "crates/ui-egui/src/canvas.rs"
    try:
        canvas_text = canvas_path.read_text()
    except OSError:
        canvas_text = ""
    blank_pan_helpers = []
    if (
        ("fn android_blank_touch_scroll(" not in canvas_text
         or "fn android_blank_touch_pan_active(" not in canvas_text)
        and "struct AndroidBlankPan {" not in canvas_text
    ):
        blank_pan_helpers.append(blank_pan_state)
    if "fn android_blank_touch_scroll(" not in canvas_text:
        blank_pan_helpers.append(blank_pan_scroll)
    if "fn android_blank_touch_pan_active(" not in canvas_text:
        blank_pan_helpers.append(blank_pan_active)
    if "fn android_pointer_over_overlay(" not in canvas_text:
        blank_pan_helpers.append(overlay_guard)
    if blank_pan_helpers and canvas_text:
        canvas_path.write_text(canvas_text.rstrip() + "\n\n" + "\n".join(blank_pan_helpers) + "\n")
        fixed.append("crates/ui-egui/src/canvas.rs (single-finger blank-area scrolling)")
    elif canvas_text and "fn android_blank_touch_scroll(" in canvas_text:
        if sub(
            "crates/ui-egui/src/canvas.rs",
            r"fn android_blank_touch_scroll\(ui: &egui::Ui, full: egui::Rect, pages: &\[egui::Rect\]\) -> egui::Vec2 \{\n.*?\n\}\n",
            blank_pan_scroll,
        ):
            fixed.append("crates/ui-egui/src/canvas.rs (block blank-area pans over UI)")

    if fix(
        "crates/ui-egui/src/canvas.rs",
        "    // Dragging a selection near the viewport's edge scrolls on (#688): from a crawl at the margin\n",
        "    let blank_touch_delta = if !app.session.view.read_mode {\n"
        "        android_blank_touch_scroll(ui, full, &app.canvas.page_rects)\n"
        "    } else {\n"
        "        egui::Vec2::ZERO\n"
        "    };\n"
        "    let wheel_delta = wheel_delta + blank_touch_delta;\n"
        "    // Dragging a selection near the viewport's edge scrolls on (#688): from a crawl at the margin\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (blank-area gestures use the wheel scroll path)")

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
    # Android sends no momentum of its own for a two-finger pan — the touchscreen's OS layer
    # has no inertia — so the app has to make the coast, exactly as it does on Linux. The
    # earlier builder patch excluded Android, which left a flick with no coast at all.
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

    # Publish WordCraft's committed text window and UTF-8 cursor offsets for the generated
    # Android IME host, which converts these offsets to UTF-16 for Gboard.
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
        "            let window = ime_window(app);\n",
        "            let window = window.clone();\n",
    ):
        fixed.append("crates/ui-egui/src/keys/ime.rs (reuse the published IME text window)")

if fixed:
    print(f"  Added two-finger-scroll patches to {title}: {', '.join(fixed)}")
PY
