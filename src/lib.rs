use tauri::{
    plugin::{Builder, TauriPlugin},
    Manager, Runtime,
};

pub use models::*;

mod commands;
#[cfg(desktop)]
mod desktop;
mod error;
#[cfg(mobile)]
mod mobile;
mod models;

#[cfg(desktop)]
use desktop::Canvas;
pub use error::{Error, Result};
#[cfg(mobile)]
use mobile::Canvas;

pub trait CanvasExt<R: Runtime> {
    fn canvas(&self) -> &Canvas<R>;
}

impl<R: Runtime, T: Manager<R>> CanvasExt<R> for T {
    fn canvas(&self) -> &Canvas<R> {
        self.state::<Canvas<R>>().inner()
    }
}

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("canvas")
        .invoke_handler(tauri::generate_handler![
            commands::show_canvas,
            commands::hide_canvas,
            commands::is_available,
            commands::activate_pen,
            commands::deactivate_pen,
            commands::clear,
            commands::undo,
            commands::redo,
            commands::get_strokes,
            commands::export_image,
        ])
        .setup(|app, api| {
            #[cfg(mobile)]
            let canvas = mobile::init(app, api)?;
            #[cfg(desktop)]
            let canvas = desktop::init(app, api)?;
            app.manage(canvas);
            Ok(())
        })
        .build()
}
