use serde::de::DeserializeOwned;
use tauri::{
    plugin::{PluginApi, PluginHandle},
    AppHandle, Runtime,
};

use crate::models::{AvailabilityResponse, CanvasConfig, ExportOptions, PenConfig, Stroke, StrokeFragment};

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_canvas);

pub fn init<R: Runtime, C: DeserializeOwned>(
    _app: &AppHandle<R>,
    api: PluginApi<R, C>,
) -> crate::Result<Canvas<R>> {
    #[cfg(target_os = "ios")]
    let handle = api.register_ios_plugin(init_plugin_canvas)?;
    Ok(Canvas(handle))
}

pub struct Canvas<R: Runtime>(PluginHandle<R>);

impl<R: Runtime> Canvas<R> {
    pub fn show_canvas(&self, config: CanvasConfig) -> crate::Result<()> {
        self.0.run_mobile_plugin("showCanvas", config).map_err(Into::into)
    }

    pub fn hide_canvas(&self) -> crate::Result<()> {
        self.0
            .run_mobile_plugin::<()>("hideCanvas", ())
            .map_err(Into::into)
    }

    pub fn is_available(&self) -> crate::Result<AvailabilityResponse> {
        self.0
            .run_mobile_plugin("isAvailable", ())
            .map_err(Into::into)
    }

    pub fn activate_pen(&self, config: PenConfig) -> crate::Result<()> {
        self.0.run_mobile_plugin("activatePen", config).map_err(Into::into)
    }

    pub fn deactivate_pen(&self) -> crate::Result<()> {
        self.0
            .run_mobile_plugin::<()>("deactivatePen", ())
            .map_err(Into::into)
    }

    pub fn clear(&self) -> crate::Result<()> {
        self.0.run_mobile_plugin::<()>("clear", ()).map_err(Into::into)
    }

    pub fn undo(&self) -> crate::Result<()> {
        self.0.run_mobile_plugin::<()>("undo", ()).map_err(Into::into)
    }

    pub fn redo(&self) -> crate::Result<()> {
        self.0.run_mobile_plugin::<()>("redo", ()).map_err(Into::into)
    }

    pub fn get_strokes(&self) -> crate::Result<Vec<Stroke>> {
        self.0
            .run_mobile_plugin("getStrokes", ())
            .map_err(Into::into)
    }

    pub fn export_image(&self, options: ExportOptions) -> crate::Result<String> {
        self.0
            .run_mobile_plugin("exportImage", options)
            .map_err(Into::into)
    }

    pub fn export_latest_stroke_fragment(&self) -> crate::Result<Option<StrokeFragment>> {
        self.0
            .run_mobile_plugin("exportLatestStrokeFragment", ())
            .map_err(Into::into)
    }
}
