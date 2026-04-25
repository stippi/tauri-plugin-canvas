const COMMANDS: &[&str] = &[
    "show_canvas",
    "hide_canvas",
    "is_available",
    "activate_pen",
    "deactivate_pen",
    "clear",
    "undo",
    "redo",
    "get_strokes",
    "export_image",
    "export_latest_stroke_fragment",
    "register_listener",
    "remove_listener",
];

fn main() {
    tauri_plugin::Builder::new(COMMANDS).ios_path("ios").build();
}
