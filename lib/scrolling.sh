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

    # A two-finger gesture scrolls the document (see the builder's patched winit backend).
    # The backend takes the gesture over from the touch path and cancels the first finger's
    # touch when the second finger lands; that cancellation is how the canvas learns a
    # gesture is in progress, so a press that belongs to the gesture does not start a text
    # selection, and a selection the first finger already began is dropped.
    #
    # egui's own multi-touch state cannot be used for this: the backend keeps egui's touch
    # state clear (it reports the gesture itself, so egui must not read the same two
    # fingers as a pinch of its own and zoom the document by accident).
    guard = (
        "/// A two-finger gesture (scroll or pinch) is in progress: a touch press during it is part\n"
        "/// of that gesture, not a click, and any text-selection drag it began must be dropped.\n"
        "///\n"
        "/// The backend takes the gesture over from the touch path and says so by cancelling the\n"
        "/// first finger's touch (see the builder's patched winit backend), so the gesture is\n"
        "/// recognised by that cancellation and not by egui's own multi-touch state (which the\n"
        "/// backend keeps clear, so that egui does not read the same fingers as a pinch).\n"
        "fn touch_gesture_active(ui: &Ui) -> bool {\n"
        "    ui.input(|i| {\n"
        "        i.events\n"
        "            .iter()\n"
        "            .any(|e| matches!(e, egui::Event::Touch { phase: egui::TouchPhase::Cancel, .. }))\n"
        "    })\n"
        "}\n"
    )
    mouse_line = (
        "fn mouse(app: &mut WordApp, ui: &Ui, resp: &egui::Response, rects: &[Rect], "
        "layout: &DocLayout, scale: f32) {"
    )
    # A source that has never been patched: add the guard. A source that already has one
    # (an earlier builder's, or an upstream that grew its own) gets it updated instead.
    if "fn touch_gesture_active" not in (src / "crates/ui-egui/src/canvas.rs").read_text():
        if fix(
            "crates/ui-egui/src/canvas.rs",
            mouse_line,
            guard + "\n" + mouse_line,
        ):
            fixed.append("crates/ui-egui/src/canvas.rs (touch gestures start no selection)")
    elif sub(
        "crates/ui-egui/src/canvas.rs",
        r"/// A two-finger gesture \(scroll or pinch\) is in progress.*?\nfn touch_gesture_active\(ui: &Ui\) -> bool \{\n.*?\n\}\n",
        guard,
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (touch gestures start no selection)")

    # Do not begin a selection on a press that is part of a two-finger gesture.
    if fix(
        "crates/ui-egui/src/canvas.rs",
        "    let pressed = ui.input(|i| i.pointer.primary_pressed()) && resp.contains_pointer() && !over_balloon(app, p);\n",
        "    let pressed = ui.input(|i| i.pointer.primary_pressed())\n"
        "        && !touch_gesture_active(ui)\n"
        "        && resp.contains_pointer()\n"
        "        && !over_balloon(app, p);\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (two-finger press does not select)")

    # A second finger arriving after the press already started a drag: drop it, so the scroll
    # never carries a selection along. Runs before the drag-extension arms below.
    if fix(
        "crates/ui-egui/src/canvas.rs",
        "    } else if app.canvas.dragging\n"
        "        && ui.input(|i| i.pointer.primary_down())\n"
        "        && let Some(d) = app.canvas.unit_drag.as_mut()\n",
        "    } else if app.canvas.dragging && touch_gesture_active(ui) {\n"
        "        // A two-finger scroll took over: stop selecting and forget the drag.\n"
        "        app.canvas.cancel_text_drag();\n"
        "    } else if app.canvas.dragging\n"
        "        && ui.input(|i| i.pointer.primary_down())\n"
        "        && let Some(d) = app.canvas.unit_drag.as_mut()\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (scroll cancels a live selection drag)")

    # A one-finger drag that starts in the blank canvas around a page is a pan, not a caret
    # selection. Keep the gesture state in egui memory and feed its deltas through the canvas
    # wheel path; a drag that starts on a page remains a normal text-selection gesture.
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
        "    if touches.is_empty() && pan.is_some_and(|active| active.ending) { pan = None; }\n"
        "    let mut delta = egui::Vec2::ZERO;\n"
        "    for (id, phase, pos) in touches {\n"
        "        match phase {\n"
        "            egui::TouchPhase::Start => {\n"
        "                pan = (full.contains(pos) && !pages.iter().any(|page| page.contains(pos)))\n"
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
    if blank_pan_helpers and canvas_text:
        canvas_path.write_text(canvas_text.rstrip() + "\n\n" + "\n".join(blank_pan_helpers) + "\n")
        fixed.append("crates/ui-egui/src/canvas.rs (single-finger blank-area scrolling)")

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

    # When Android reports an IME inset, dock WordCraft's selected-text toolbar above the
    # keyboard instead of anchoring it over the selected line.
    if fix(
        "crates/ui-egui/src/mini_toolbar.rs",
        "    let Some(bar) = anchor_rect(selection.min.y, selection.min.x, viewport) else { return };\n",
        "    let ime_bottom = if cfg!(target_os = \"android\") {\n"
        "        ctx.data(|data| data.get_temp::<f32>(egui::Id::new(\"android_ime_bottom_inset\"))).unwrap_or(0.0)\n"
        "    } else { 0.0 };\n"
        "    let toolbar_viewport = egui::Rect::from_min_max(\n"
        "        viewport.min,\n"
        "        egui::pos2(viewport.max.x, (viewport.max.y - ime_bottom).max(viewport.min.y)),\n"
        "    );\n"
        "    let bar = if ime_bottom > 0.0 {\n"
        "        let x = (selection.center().x - BAR_W * 0.5).clamp(\n"
        "            toolbar_viewport.left(),\n"
        "            (toolbar_viewport.right() - BAR_W).max(toolbar_viewport.left()),\n"
        "        );\n"
        "        let y = (toolbar_viewport.bottom() - BAR_H).max(toolbar_viewport.top());\n"
        "        egui::Rect::from_min_size(egui::pos2(x, y), egui::vec2(BAR_W, BAR_H))\n"
        "    } else {\n"
        "        let Some(bar) = anchor_rect(selection.min.y, selection.min.x, toolbar_viewport) else { return };\n"
        "        bar\n"
        "    };\n",
    ):
        fixed.append("crates/ui-egui/src/mini_toolbar.rs (dock the toolbar above the keyboard)")

    if fix(
        "crates/ui-egui/src/mini_toolbar.rs",
        "    let shown = bar.intersect(viewport);\n",
        "    let shown = bar.intersect(toolbar_viewport);\n",
    ):
        fixed.append("crates/ui-egui/src/mini_toolbar.rs (clip the toolbar to the visible area)")
    if fix(
        "crates/ui-egui/src/mini_toolbar.rs",
        "    let area = area.constrain_to(viewport).constrain(false).fixed_pos(bar.min);\n",
        "    let area = area.constrain_to(toolbar_viewport).constrain(false).fixed_pos(bar.min);\n",
    ):
        fixed.append("crates/ui-egui/src/mini_toolbar.rs (keep toolbar clicks above the keyboard)")

    # Do not raise the keyboard automatically on the first frame.
    if fix(
        "crates/ui-egui/src/canvas.rs",
        "            want_focus: true,\n",
        "            want_focus: false,\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (no keyboard before the first tap)")

    # Keep the Android IME active while the user scrolls.
    # The IME output for a caret inside a slot (a table cell or a text box) only asks for the
    # keyboard when there is a real text caret.
    if sub(
        "crates/ui-egui/src/canvas.rs",
        r"                if focused \{\n"
        r"                    ui\.ctx\(\)\.request_repaint_after\(std::time::Duration::from_millis\(530 - \(since as u64 % 530\)\)\);\n"
        r"                    let cr = Rect::from_min_max\(pos2\(x, y0\), pos2\(x \+ 1\.0, y1\)\);\n"
        r"                    ui\.ctx\(\)\.output_mut\(\|o\| \{\n"
        r"                        o\.ime = Some\(egui::output::IMEOutput \{\n"
        r"                            rect: cr,\n"
        r"                            cursor_rect: cr,\n"
        r"                            purpose: Default::default\(\),\n"
        r"                            should_interrupt_composition: ime_reset,\n"
        r"                        \}\);\n"
        r"                    \}\);\n"
        r"                \}\n",
        "                // A real text caret (a collapsed selection), not just canvas focus.\n"
        "                let has_text_caret = app.session.sel.is_collapsed() && focused;\n"
        "                if has_text_caret {\n"
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
        fixed.append("crates/ui-egui/src/canvas.rs (preserve the text caret for IME)")

    # Keep the body caret and IME candidate placement active during scrolling.
    if sub(
        "crates/ui-egui/src/canvas.rs",
        r"            if focused \{\n"
        r"                ui\.ctx\(\)\.request_repaint_after\(std::time::Duration::from_millis\(530 - \(since as u64 % 530\)\)\);\n"
        r"            \}\n"
        r"            // IME candidate window placement\.\n"
        r"            let cr = Rect::from_min_max\(pos2\(x, y0\), pos2\(x \+ 1\.0, y1\)\);\n"
        r"            if focused \{\n",
        "            if shown {\n"
        "                ui.ctx().request_repaint_after(std::time::Duration::from_millis(530 - (since as u64 % 530)));\n"
        "            }\n"
        "            // IME candidate window placement.\n"
        "            let cr = Rect::from_min_max(pos2(x, y0), pos2(x + 1.0, y1));\n"
        "            if shown {\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (preserve the body caret for IME)")

    # A blank-area pan should not steal the document's text focus or raise the keyboard.
    if fix(
        "crates/ui-egui/src/canvas.rs",
        "    let focus_click = pointer_click || accesskit_click || resp.drag_started();\n",
        "    let blank_touch_pan = crate::canvas::android_blank_touch_pan_active(ui.ctx());\n"
        "    let focus_click = ((pointer_click || resp.drag_started()) && !blank_touch_pan) || accesskit_click;\n",
    ):
        fixed.append("crates/ui-egui/src/canvas.rs (a scroll or a draw takes no focus)")

    # Upgrade focus patches already present in reused source checkouts.
    for old, new in (
        (
            "    let middle_gesture = app.canvas.auto_scroll.blocks_input();\n"
            "    let is_drawing =",
            "    let middle_gesture = app.canvas.auto_scroll.blocks_input();\n"
            "    let blank_touch_pan = crate::canvas::android_blank_touch_pan_active(ui.ctx());\n"
            "    let is_drawing =",
        ),
        (
            "    let is_text_drag = resp.drag_started()\n"
            "        && !middle_gesture\n"
            "        && !is_drawing\n",
            "    let is_text_drag = resp.drag_started()\n"
            "        && !middle_gesture\n"
            "        && !blank_touch_pan\n"
            "        && !is_drawing\n",
        ),
        (
            "    let focus_click = (pointer_click && !is_drawing) || accesskit_click || is_text_drag;\n",
            "    let focus_click = (pointer_click && !is_drawing && !blank_touch_pan) || accesskit_click || is_text_drag;\n",
        ),
    ):
        if upgrade("crates/ui-egui/src/canvas.rs", old, new):
            fixed.append("crates/ui-egui/src/canvas.rs (upgrade blank-area pan focus handling)")

    # Remove the unused pan-state read inserted by an earlier builder patch in finish_canvas_frame.
    rewrite(
        "crates/ui-egui/src/canvas.rs",
        "    let blank_touch_pan = crate::canvas::android_blank_touch_pan_active(ui.ctx());\n"
        "    handle_primary_pointer(app, ui, &resp, &rects, layout, geo, middle_gesture);\n",
        "    handle_primary_pointer(app, ui, &resp, &rects, layout, geo, middle_gesture);\n",
    )

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

if fixed:
    print(f"  Added two-finger-scroll patches to {title}: {', '.join(fixed)}")
PY
