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
];

fn main() {
    tauri_plugin::Builder::new(COMMANDS)
        .ios_path("ios")
        .build();
}
