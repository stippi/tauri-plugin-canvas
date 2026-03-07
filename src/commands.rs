use tauri::{command, AppHandle, Runtime};

use crate::models::{AvailabilityResponse, CanvasConfig, ExportOptions, PenConfig, Stroke};
use crate::{CanvasExt, Result};

#[command]
pub(crate) async fn show_canvas<R: Runtime>(
    app: AppHandle<R>,
    config: Option<CanvasConfig>,
) -> Result<()> {
    app.canvas().show_canvas(config.unwrap_or_default())
}

#[command]
pub(crate) async fn hide_canvas<R: Runtime>(app: AppHandle<R>) -> Result<()> {
    app.canvas().hide_canvas()
}

#[command]
pub(crate) async fn is_available<R: Runtime>(app: AppHandle<R>) -> Result<AvailabilityResponse> {
    app.canvas().is_available()
}

#[command]
pub(crate) async fn activate_pen<R: Runtime>(
    app: AppHandle<R>,
    config: Option<PenConfig>,
) -> Result<()> {
    app.canvas().activate_pen(config.unwrap_or_default())
}

#[command]
pub(crate) async fn deactivate_pen<R: Runtime>(app: AppHandle<R>) -> Result<()> {
    app.canvas().deactivate_pen()
}

#[command]
pub(crate) async fn clear<R: Runtime>(app: AppHandle<R>) -> Result<()> {
    app.canvas().clear()
}

#[command]
pub(crate) async fn undo<R: Runtime>(app: AppHandle<R>) -> Result<()> {
    app.canvas().undo()
}

#[command]
pub(crate) async fn redo<R: Runtime>(app: AppHandle<R>) -> Result<()> {
    app.canvas().redo()
}

#[command]
pub(crate) async fn get_strokes<R: Runtime>(app: AppHandle<R>) -> Result<Vec<Stroke>> {
    app.canvas().get_strokes()
}

#[command]
pub(crate) async fn export_image<R: Runtime>(
    app: AppHandle<R>,
    options: Option<ExportOptions>,
) -> Result<String> {
    app.canvas().export_image(options.unwrap_or_default())
}
