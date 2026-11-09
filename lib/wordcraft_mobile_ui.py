#!/usr/bin/env python3
"""Apply WordCraft-only responsive Backstage and recent-file deletion patches."""

from pathlib import Path
import re
import sys


src = Path(sys.argv[1])
title = sys.argv[2]


def patch(rel: str, marker: str, pattern: str, replacement: str) -> bool:
    path = src / rel
    text = path.read_text()
    if marker in text:
        return False
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f"{title}: cannot apply mobile UI patch to {rel}; upstream layout changed")
    path.write_text(updated)
    return True


def replace(rel: str, marker: str, old: str, new: str) -> bool:
    path = src / rel
    text = path.read_text()
    if marker in text:
        return False
    if old not in text:
        raise SystemExit(f"{title}: cannot apply mobile UI patch to {rel}; upstream anchor missing")
    path.write_text(text.replace(old, new, 1))
    return True


changes = []

if patch(
    "crates/ui-egui/src/services.rs",
    "pub delete_file: Option<Box<dyn Fn(&str) -> Result<(), String>>>,",
    r"pub struct Services \{\n",
    "pub struct Services {\n"
    "    /// Android: delete a document selected from Recents, including its SAF original.\n"
    "    pub delete_file: Option<Box<dyn Fn(&str) -> Result<(), String>>>,\n",
):
    changes.append("Android document deletion service")

lib_path = src / "crates/ui-egui/src/lib.rs"
lib_text = lib_path.read_text()
lib_text = re.sub(
    r"    /// File › Options › General: skip confirmation when deleting a document from Recents\.\n"
    r"    pub always_delete_recent: bool,\n",
    "",
    lib_text,
)
lib_text = lib_text.replace("            always_delete_recent: false,\n", "")
if "pub backstage_nav_collapsed: Option<bool>," not in lib_text:
    lib_text = lib_text.replace(
        "    pub recent: Vec<String>,\n",
        "    pub recent: Vec<String>,\n"
        "    /// Collapsed state of the File sidebar; None follows the available display width.\n"
        "    pub backstage_nav_collapsed: Option<bool>,\n",
        1,
    )
if "backstage_nav_collapsed: None," not in lib_text:
    lib_text = lib_text.replace("            recent: Vec::new(),\n", "            recent: Vec::new(),\n            backstage_nav_collapsed: None,\n", 1)
lib_path.write_text(lib_text)

options_page = r'''/// The Options page.
pub fn page(app: &mut WordApp, ui: &mut Ui) {
    let t = Tokens::get(ui.ctx());
    ui.label(RichText::new(tl!("Options")).font(semibold(26.0)));
    ui.add_space(16.0);
    let current = if PANES.contains(&app.ui.options_pane.as_str()) { app.ui.options_pane.clone() } else { "general".to_string() };
    if ui.available_width() < 620.0 {
        ui.horizontal_wrapped(|ui| {
            for id in PANES {
                let label = tl!(pane_label(id));
                if ui.selectable_label(current == id, label).clicked() {
                    app.ui.options_pane = id.to_string();
                }
            }
        });
        ui.separator();
        show_options_pane(app, ui, &current);
        return;
    }
    ui.horizontal_top(|ui| {
        ui.vertical(|ui| {
            ui.set_width(170.0);
            for id in PANES {
                let label = tl!(pane_label(id));
                let active = current == id;
                let (r, resp) = ui.allocate_exact_size(vec2(170.0, 30.0), egui::Sense::click());
                resp.widget_info(|| egui::WidgetInfo::selected(egui::Role::Button, true, active, label));
                if active {
                    ui.painter().rect_filled(r, 4.0, t.checked);
                } else if resp.hovered() {
                    ui.painter().rect_filled(r, 4.0, t.hover);
                }
                let font = if active { semibold(14.0) } else { crate::theme::regular(14.0) };
                ui.painter().with_clip_rect(r).text(egui::pos2(r.min.x + 12.0, r.center().y), egui::Align2::LEFT_CENTER, label, font, t.text);
                if resp.clicked() {
                    app.ui.options_pane = id.to_string();
                }
            }
        });
        ui.add_space(12.0);
        let (line, _) = ui.allocate_exact_size(vec2(1.0, 420.0), egui::Sense::hover());
        ui.painter().rect_filled(line, 0.0, t.border);
        ui.add_space(20.0);
        show_options_pane(app, ui, &current);
    });
}

fn show_options_pane(app: &mut WordApp, ui: &mut Ui, current: &str) {
    ui.vertical(|ui| {
        let max_width = ui.available_width().min(640.0);
        ui.set_max_width(max_width);
        match current {
            "display" => display(app, ui),
            "proofing" => proofing(app, ui),
            "save" => save(app, ui),
            "language" => language(app, ui),
            "accessibility" => accessibility(app, ui),
            "advanced" => advanced(app, ui),
            "agents" => agents(ui),
            _ => general(app, ui),
        }
    });
}

'''
if patch(
    "crates/ui-egui/src/options.rs",
    "fn show_options_pane(app: &mut WordApp, ui: &mut Ui, current: &str)",
    r"/// The Options page\.\n.*?(?=\nfn section\()",
    options_page.rstrip(),
):
    changes.append("portrait-friendly Options layout")

options_path = src / "crates/ui-egui/src/options.rs"
options_text = options_path.read_text()
options_text = re.sub(
    r'^\s*ui\.checkbox\(&mut app\.ui\.always_delete_recent, '
    r'tl!\("Always delete documents from Recents without asking"\)\)\n'
    r'\s*\.on_hover_text\(tl!\("You can turn this off here at any time\."\)\);\n',
    "",
    options_text,
    flags=re.M,
)
options_path.write_text(options_text)

window_ui_path = src / "crates/ui-egui/src/window_ui.rs"
window_ui_text = window_ui_path.read_text().replace("            always_delete_recent: _,\n", "")
if "            backstage_nav_collapsed: _,\n" not in window_ui_text:
    window_ui_text = window_ui_text.replace("            recent: _,\n", "            recent: _,\n            backstage_nav_collapsed: _,\n", 1)
window_ui_path.write_text(window_ui_text)

options_path = src / "crates/ui-egui/src/options.rs"
options_text = options_path.read_text()
for old, new in (
    (".desired_width(260.0)", ".desired_width((ui.available_width() * 0.5).min(260.0))"),
    (".desired_width(320.0)", ".desired_width((ui.available_width() * 0.5).min(320.0))"),
    (".desired_width(220.0)", ".desired_width((ui.available_width() * 0.5).min(220.0))"),
    (".desired_width(80.0)", ".desired_width((ui.available_width() * 0.5).min(80.0))"),
):
    options_text = options_text.replace(old, new)
options_path.write_text(options_text)

backstage_path = src / "crates/ui-egui/src/backstage.rs"
backstage_text = backstage_path.read_text()
backstage_text = backstage_text.replace(
    '.desired_width(360.0)',
    '.desired_width(ui.available_width().min(360.0))',
)
backstage_path.write_text(backstage_text)

backstage_show = r'''pub fn show(app: &mut WordApp, ui: &mut Ui) {
    let t = Tokens::get(ui.ctx());
    let has_document = app.has_document();
    if !has_document && !works_without_document(&app.ui.backstage_page) {
        app.ui.backstage_page = "home".into();
    }
    let narrow = ui.available_width() < 700.0;
    let collapsed = app.ui.backstage_nav_collapsed.unwrap_or(narrow);
    let nav_width = if collapsed { 64.0 } else { 200.0 };
    let content_margin = if narrow { 16 } else { 40 };
    let content_vertical_margin = if narrow { 20 } else { 30 };
    let mac = app.integrated_titlebar;
    egui::Panel::left("backstage_nav")
        .exact_size(nav_width)
        .resizable(false)
        .frame(egui::Frame::NONE.fill(t.nav).inner_margin(egui::Margin { left: 0, right: 0, top: if mac { 0 } else { 12 }, bottom: 12 }))
        .show(ui, |ui| {
            let back = if mac {
                let (band, drag) = ui.allocate_exact_size(vec2(nav_width, app.mac_titlebar.height), Sense::click_and_drag());
                if drag.drag_started() {
                    ui.ctx().send_viewport_cmd(egui::ViewportCommand::StartDrag);
                }
                let c = back_chevron_c(band.min.x, band.center().y, app.session.view.full_screen, app.mac_titlebar.content_left);
                let resp = ui.interact(Rect::from_center_size(c, vec2(22.0, band.height())), ui.scope_id().with("backstage_back"), Sense::click());
                icons::paint(ui.painter(), Rect::from_center_size(c, vec2(18.0, 18.0)), "chevronLeft", egui::Color32::WHITE, egui::Color32::WHITE);
                resp
            } else {
                let (r, _) = ui.allocate_exact_size(vec2(nav_width, 40.0), Sense::hover());
                let c = pos2(r.min.x + 26.0, r.center().y);
                let resp = ui.interact(Rect::from_center_size(c, vec2(22.0, r.height())), ui.scope_id().with("backstage_back"), Sense::click());
                icons::paint(ui.painter(), Rect::from_center_size(c, vec2(18.0, 18.0)), "chevronLeft", egui::Color32::WHITE, egui::Color32::WHITE);
                resp
            };
            if back.clicked() || (!app.file_dialog_open() && ui.input(|i| i.key_pressed(egui::Key::Escape))) {
                app.ui.backstage = false;
                app.canvas.want_focus = true;
            }
            ui.add_space(if mac { 8.0 } else { 2.0 });
            let (toggle_rect, toggle) = ui.allocate_exact_size(vec2(nav_width, 38.0), Sense::click());
            toggle.widget_info(|| egui::WidgetInfo::labeled(egui::Role::Button, true, if collapsed { "Expand menu" } else { "Collapse menu" }));
            if toggle.hovered() {
                ui.painter().rect_filled(toggle_rect, 0.0, egui::Color32::from_white_alpha(26));
            }
            let center = toggle_rect.center();
            for offset in [-5.0, 0.0, 5.0] {
                ui.painter().line_segment(
                    [pos2(center.x - 8.0, center.y + offset), pos2(center.x + 8.0, center.y + offset)],
                    Stroke::new(1.8, egui::Color32::WHITE),
                );
            }
            if toggle.on_hover_text(if collapsed { "Expand menu" } else { "Collapse menu" }).clicked() {
                app.ui.backstage_nav_collapsed = Some(!collapsed);
            }
            ui.add_space(4.0);
            for (id, label, icon) in PAGES {
                let on = has_document || works_without_document(id);
                let (r, resp) = ui.add_enabled_ui(on, |ui| ui.allocate_exact_size(vec2(nav_width, 38.0), Sense::click())).inner;
                resp.widget_info(|| egui::WidgetInfo::labeled(egui::Role::Button, on, tl!(label)));
                let active = app.ui.backstage_page == id;
                if active {
                    ui.painter().rect_filled(r, 0.0, egui::Color32::from_white_alpha(46));
                } else if on && resp.hovered() {
                    ui.painter().rect_filled(r, 0.0, egui::Color32::from_white_alpha(26));
                }
                let ink = if on { egui::Color32::WHITE } else { egui::Color32::from_white_alpha(110) };
                let icon_x = if collapsed { r.center().x } else { r.min.x + 31.0 };
                icons::paint(ui.painter(), Rect::from_center_size(pos2(icon_x, r.center().y), vec2(18.0, 18.0)), icon, ink, ink);
                if !collapsed {
                    ui.painter().text(
                        pos2(r.min.x + 52.0, r.center().y),
                        egui::Align2::LEFT_CENTER,
                        tl!(label),
                        if active { semibold(14.0) } else { medium(14.0) },
                        ink,
                    );
                }
                if on
                    && app.ui.keytips == crate::keytips::Phase::Backstage
                    && let Some(letter) = keytip_letter(id)
                {
                    crate::keytips::badge(ui, Rect::from_min_size(pos2(r.min.x + 16.0, r.min.y), vec2(20.0, 16.0)), letter);
                }
                if resp.clicked() {
                    go_to_page(app, id);
                }
            }
            ui.with_layout(egui::Layout::bottom_up(egui::Align::Min), |ui| {
                let orientation_id = egui::Id::new("artcraft_android_screen_orientation_locked");
                let orientation_locked = ui.ctx().data(|data| data.get_temp::<bool>(orientation_id)).unwrap_or(false);
                let (r, _) = ui.allocate_exact_size(vec2(nav_width, 44.0), Sense::hover());
                let center = pos2(if collapsed { r.center().x } else { r.min.x + 26.0 }, r.center().y);
                let button_rect = Rect::from_center_size(center, vec2(36.0, 36.0));
                let description = if orientation_locked { "Unlock screen rotation" } else { "Lock screen rotation" };
                let rotation = ui.interact(button_rect, ui.make_persistent_id("android_screen_rotation"), Sense::click());
                rotation.widget_info(|| egui::WidgetInfo::labeled(egui::Role::Button, true, tl!(description)));
                ui.painter().circle_filled(
                    center,
                    18.0,
                    if orientation_locked { egui::Color32::from_rgb(224, 138, 0) }
                    else if rotation.hovered() { egui::Color32::from_white_alpha(46) }
                    else { egui::Color32::from_white_alpha(26) },
                );
                ui.painter().text(center, egui::Align2::CENTER_CENTER, "↻", semibold(22.0), egui::Color32::WHITE);
                if !collapsed {
                    ui.painter().text(
                        pos2(r.min.x + 52.0, r.center().y),
                        egui::Align2::LEFT_CENTER,
                        tl!(description),
                        regular(13.0),
                        egui::Color32::WHITE,
                    );
                }
                if rotation.on_hover_text(tl!(description)).clicked() {
                    ui.ctx().data_mut(|data| data.insert_temp(orientation_id, !orientation_locked));
                }
                for (label, id, icon) in [("About", "about", "help"), ("Discord community", "discord", "discord")] {
                    let (r, resp) = ui.allocate_exact_size(vec2(nav_width, 32.0), Sense::click());
                    resp.widget_info(|| egui::WidgetInfo::labeled(egui::Role::Button, ui.is_enabled(), tl!(label)));
                    if resp.hovered() {
                        ui.painter().rect_filled(r, 0.0, egui::Color32::from_white_alpha(26));
                    }
                    let icon_x = if collapsed { r.center().x } else { r.min.x + 22.0 };
                    icons::paint(ui.painter(), Rect::from_center_size(pos2(icon_x, r.center().y), vec2(18.0, 18.0)), icon, egui::Color32::WHITE, egui::Color32::WHITE);
                    if !collapsed {
                        ui.painter().text(pos2(r.min.x + 38.0, r.center().y), egui::Align2::LEFT_CENTER, tl!(label), regular(13.0), egui::Color32::WHITE);
                    }
                    if resp.clicked() {
                        if id == "discord" {
                            let _ = app.run("ui.discord", json!({}));
                        } else {
                            app.dialog = crate::dialogs::Dialog::open("about", app);
                        }
                    }
                }
            });
        });
    egui::CentralPanel::default()
        .frame(egui::Frame::NONE.fill(t.ribbon).inner_margin(egui::Margin::symmetric(content_margin, content_vertical_margin)))
        .show(ui, |ui| {
            if app.ui.backstage_page == "print" {
                export_page(app, ui);
                return;
            }
            egui::ScrollArea::vertical().show(ui, |ui| match app.ui.backstage_page.as_str() {
                "home" => home_page(app, ui),
                "new" => new_page(app, ui),
                "open" => open_page(app, ui),
                "saveAs" => save_as_page(app, ui),
                "info" => info_page(app, ui),
                "recover" => recovery_page(app, ui),
                "print" | "export" => export_page(app, ui),
                "options" => crate::options::page(app, ui),
                _ => home_page(app, ui),
            });
        });
    show_delete_prompt(app, ui.ctx());
}

'''
if patch(
    "crates/ui-egui/src/backstage.rs",
    "fn show_delete_prompt(app: &mut WordApp, ctx: &egui::Context)",
    r"pub fn show\(app: &mut WordApp, ui: &mut Ui\) \{\n.*?(?=\n/// Recovery is a separate copy\.)",
    backstage_show,
):
    changes.append("collapsible responsive Backstage sidebar")

if replace(
    "crates/ui-egui/src/backstage.rs",
    "ui.horizontal_wrapped(|ui| {\n        ui.spacing_mut().item_spacing = vec2(18.0, 0.0);",
    "    ui.horizontal(|ui| {\n        ui.spacing_mut().item_spacing = vec2(18.0, 0.0);\n",
    "    ui.horizontal_wrapped(|ui| {\n        ui.spacing_mut().item_spacing = vec2(18.0, 0.0);\n",
):
    changes.append("wrapping Home template gallery")

if replace(
    "crates/ui-egui/src/backstage.rs",
    "let galley = ui.painter().layout(caption.to_string(), regular(12.5), ui.visuals().text_color(), 150.0);",
    "        let galley = ui.painter().layout_no_wrap(caption.to_string(), regular(12.5), ui.visuals().text_color());\n",
    "        let galley = ui.painter().layout(caption.to_string(), regular(12.5), ui.visuals().text_color(), 150.0);\n",
):
    changes.append("wrapping template captions")

recent_list = r'''fn open_list(app: &mut WordApp, ui: &mut Ui) {
    let t = Tokens::get(ui.ctx());
    ui.label(egui::RichText::new(tl!("Recent")).font(semibold(16.0)));
    ui.add_space(6.0);
    let error = ui.ctx().data(|d| d.get_temp::<String>(open_error_id())).unwrap_or_default();
    if !error.is_empty() {
        ui.label(egui::RichText::new(error).color(ui.visuals().error_fg_color));
        ui.add_space(6.0);
    }
    if app.ui.recent.is_empty() {
        ui.label(egui::RichText::new(tl!("Documents you open will show up here.")).color(t.text_dim));
    }
    let shown = app.ui.recent.iter().take(app.ui.recent_shown()).cloned().collect::<Vec<_>>();
    let file_name = |p: &str| std::path::Path::new(p).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or(p.to_string());
    let names = shown.iter().map(|p| file_name(p)).collect::<Vec<_>>();
    for (p, name) in shown.iter().zip(&names) {
        let available = ui.available_rect_before_wrap();
        let row_width = (available.right().min(ui.clip_rect().right()) - available.left()).clamp(0.0, 700.0);
        let can_delete = app.services.delete_file.is_some();
        let delete_width = if can_delete { 42.0 } else { 0.0 };
        let text_width = (row_width - 58.0 - delete_width).max(32.0);
        let name_galley = ui.painter().layout(name.clone(), medium(13.0), t.text, text_width);
        let path_galley = ui.painter().layout(p.clone(), regular(11.0), t.text_dim, text_width);
        let name_height = name_galley.size().y;
        let row_height = (name_height + path_galley.size().y + 12.0).max(48.0);
        let (row, _) = ui.allocate_exact_size(vec2(row_width, row_height), Sense::hover());
        let text_rect = Rect::from_min_max(pos2(row.min.x + 42.0, row.min.y + 5.0), pos2(row.min.x + 42.0 + text_width, row.max.y - 5.0));
        let open_rect = Rect::from_min_max(row.min, pos2(if can_delete { row.max.x - delete_width } else { row.max.x }, row.max.y));
        let open = ui.interact(open_rect, ui.make_persistent_id(("recent-open", p)), Sense::click());
        let spoken = if names.iter().filter(|n| *n == name).count() > 1 { format!("{name}, {p}") } else { name.clone() };
        open.widget_info(|| egui::WidgetInfo::labeled(egui::Role::Button, ui.is_enabled(), &spoken));
        if open.hovered() {
            ui.painter().rect_filled(row, 4.0, t.hover);
        }
        icons::paint(ui.painter(), Rect::from_center_size(pos2(row.min.x + 20.0, row.center().y), vec2(22.0, 22.0)), "printLayout", t.icon, t.accent);
        ui.painter().galley(text_rect.min, name_galley, t.text);
        ui.painter().galley(pos2(text_rect.min.x, text_rect.min.y + name_height), path_galley, t.text_dim);
        if open.clicked() {
            let failed = open_recent(app, p).err();
            ui.ctx().data_mut(|d| d.insert_temp(open_error_id(), failed.unwrap_or_default()));
        }
        if can_delete {
            let delete_rect = Rect::from_center_size(pos2(row.max.x - 20.0, row.center().y), vec2(36.0, 36.0));
            let delete = ui.interact(delete_rect, ui.make_persistent_id(("recent-delete", p)), Sense::click());
            delete.widget_info(|| egui::WidgetInfo::labeled(egui::Role::Button, true, format!("Delete {spoken}")));
            if delete.hovered() {
                ui.painter().circle_filled(delete_rect.center(), 18.0, t.hover);
            }
            let c = delete_rect.center();
            let ink = if delete.hovered() { t.accent } else { t.text_dim };
            ui.painter().line_segment([pos2(c.x - 7.0, c.y - 8.0), pos2(c.x + 7.0, c.y - 8.0)], Stroke::new(1.7, ink));
            ui.painter().line_segment([pos2(c.x - 4.0, c.y - 11.0), pos2(c.x + 4.0, c.y - 11.0)], Stroke::new(1.7, ink));
            ui.painter().line_segment([pos2(c.x - 5.0, c.y - 6.0), pos2(c.x - 4.0, c.y + 8.0)], Stroke::new(1.7, ink));
            ui.painter().line_segment([pos2(c.x + 5.0, c.y - 6.0), pos2(c.x + 4.0, c.y + 8.0)], Stroke::new(1.7, ink));
            ui.painter().line_segment([pos2(c.x - 4.0, c.y + 8.0), pos2(c.x + 4.0, c.y + 8.0)], Stroke::new(1.7, ink));
            ui.painter().line_segment([pos2(c.x - 2.0, c.y - 4.0), pos2(c.x - 2.0, c.y + 5.0)], Stroke::new(1.2, ink));
            ui.painter().line_segment([pos2(c.x + 2.0, c.y - 4.0), pos2(c.x + 2.0, c.y + 5.0)], Stroke::new(1.2, ink));
            if delete.on_hover_text(tl!("Delete this file")).clicked() {
                request_recent_delete(ui.ctx(), p);
            }
        }
    }
}

fn delete_prompt_id() -> egui::Id {
    egui::Id::unique("android_recent_delete_prompt")
}

fn request_recent_delete(ctx: &egui::Context, path: &str) {
    ctx.data_mut(|data| data.insert_temp(delete_prompt_id(), path.to_owned()));
}

fn hide_recent(app: &mut WordApp, path: &str) {
    app.ui.recent.retain(|recent| recent != path);
}

fn delete_recent(app: &mut WordApp, ctx: &egui::Context, path: &str) {
    let open_document = app.session.path.as_deref() == Some(std::path::Path::new(path));
    let result = if open_document {
        Err("Close this document before deleting it.".to_owned())
    } else if let Some(delete_file) = app.services.delete_file.as_ref() {
        delete_file(path)
    } else {
        Err("Deleting files is not available on this platform.".to_owned())
    };
    match result {
        Ok(()) => app.ui.recent.retain(|recent| recent != path),
        Err(error) => {
            log::error!("Could not delete recent WordCraft document {path}: {error}");
            ctx.data_mut(|data| data.insert_temp(open_error_id(), error));
        }
    }
}

fn show_delete_prompt(app: &mut WordApp, ctx: &egui::Context) {
    let Some(path) = ctx.data(|data| data.get_temp::<String>(delete_prompt_id())) else { return };
    let mut open = true;
    let width = (ctx.content_rect().width() - 32.0).clamp(240.0, 420.0);
    let mut hide = false;
    let mut erase = false;
    let mut cancel = false;
    let is_open = app.session.path.as_deref() == Some(std::path::Path::new(&path));
    egui::Window::new(tl!("Delete document?"))
        .id(egui::Id::new("android_recent_delete_window"))
        .collapsible(false)
        .resizable(false)
        .default_width(width)
        .open(&mut open)
        .show(ctx, |ui| {
            ui.set_max_width(width);
            ui.label(tl!("Do you want to hide it from the list only, or permanently erase the file from this device?"));
            ui.add_space(8.0);
            if is_open {
                ui.label(tl!("Close this document before erasing it from the device."));
            }
            ui.horizontal_wrapped(|ui| {
                hide = ui.button(tl!("Only from the list")).clicked();
                let erase_label = egui::RichText::new(tl!("Erase from device")).color(ui.visuals().error_fg_color);
                erase = ui.add_enabled(!is_open, egui::Button::new(erase_label)).clicked();
                cancel = ui.button(tl!("Cancel")).clicked();
            });
        });
    if !open || cancel || hide || erase {
        ctx.data_mut(|data| data.remove::<String>(delete_prompt_id()));
    }
    if hide {
        hide_recent(app, &path);
    } else if erase {
        delete_recent(app, ctx, &path);
    }
}

'''
if patch(
    "crates/ui-egui/src/backstage.rs",
    "fn show_delete_prompt(app: &mut WordApp, ctx: &egui::Context)",
    r"fn open_list\(app: &mut WordApp, ui: &mut Ui\) \{\n.*?(?=\n/// Stable storage id for the Recent list's open error\.)",
    recent_list,
):
    changes.append("recent-file trash action and confirmation")

backstage_path = src / "crates/ui-egui/src/backstage.rs"
backstage_text = backstage_path.read_text()
legacy_helper_start = backstage_text.find("fn delete_prompt_id() -> egui::Id {")
legacy_helper_end = backstage_text.find("/// Stable storage id for the Recent list's open error.", legacy_helper_start)
if legacy_helper_start != -1 and legacy_helper_end != -1:
    helper_start = recent_list.index("fn delete_prompt_id() -> egui::Id {")
    backstage_text = (
        backstage_text[:legacy_helper_start]
        + recent_list[helper_start:]
        + backstage_text[legacy_helper_end:]
    )
    backstage_path.write_text(backstage_text)

backstage_text = backstage_path.read_text()
backstage_text = backstage_text.replace(
    "let row_width = ui.available_width().min(700.0).max(80.0);",
    "let available = ui.available_rect_before_wrap();\n"
    "        let row_width = (available.right().min(ui.clip_rect().right()) - available.left()).clamp(0.0, 700.0);",
)
backstage_text = backstage_text.replace("request_recent_delete(app, ui.ctx(), p);", "request_recent_delete(ui.ctx(), p);")
backstage_text = backstage_text.replace(
    "fn request_recent_delete(app: &mut WordApp, ctx: &egui::Context, path: &str)",
    "fn request_recent_delete(ctx: &egui::Context, path: &str)",
)
backstage_text = backstage_text.replace("ctx.screen_rect()", "ctx.content_rect()")
for old, new in (
    ('tl!("Удалить документ?")', 'tl!("Delete document?")'),
    (
        'tl!("Вы хотите только скрыть его из списка или полностью стереть файл из памяти устройства?")',
        'tl!("Do you want to hide it from the list only, or permanently erase the file from this device?")',
    ),
    ('tl!("Перед удалением с устройства закройте этот документ.")', 'tl!("Close this document before erasing it from the device.")'),
    ('tl!("Только из списка")', 'tl!("Only from the list")'),
    ('tl!("Стереть с устройства")', 'tl!("Erase from device")'),
    ('tl!("Отмена")', 'tl!("Cancel")'),
):
    backstage_text = backstage_text.replace(old, new)
backstage_path.write_text(backstage_text)

if changes:
    print(f"  Applied WordCraft mobile UI changes to {title}: {', '.join(changes)}")
