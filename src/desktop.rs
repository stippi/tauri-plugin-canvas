use serde::de::DeserializeOwned;
use tauri::{plugin::PluginApi, AppHandle, Runtime};

use crate::models::{AvailabilityResponse, CanvasConfig, ExportOptions, PenConfig, Stroke, StrokeFragment};

pub fn init<R: Runtime, C: DeserializeOwned>(
    app: &AppHandle<R>,
    _api: PluginApi<R, C>,
) -> crate::Result<Canvas<R>> {
    Ok(Canvas { app: app.clone() })
}

pub struct Canvas<R: Runtime> {
    #[allow(dead_code)]
    app: AppHandle<R>,
}

impl<R: Runtime> Canvas<R> {
    pub fn show_canvas(&self, _config: CanvasConfig) -> crate::Result<()> {
        Ok(())
    }

    pub fn hide_canvas(&self) -> crate::Result<()> {
        Ok(())
    }

    pub fn is_available(&self) -> crate::Result<AvailabilityResponse> {
        Ok(AvailabilityResponse {
            available: false,
            reason: Some("Apple Pencil overlay is only available on iOS".into()),
        })
    }

    pub fn activate_pen(&self, _config: PenConfig) -> crate::Result<()> {
        Ok(())
    }

    pub fn deactivate_pen(&self) -> crate::Result<()> {
        Ok(())
    }

    pub fn clear(&self) -> crate::Result<()> {
        Ok(())
    }

    pub fn undo(&self) -> crate::Result<()> {
        Ok(())
    }

    pub fn redo(&self) -> crate::Result<()> {
        Ok(())
    }

    pub fn get_strokes(&self) -> crate::Result<Vec<Stroke>> {
        Ok(Vec::new())
    }

    pub fn export_image(&self, _options: ExportOptions) -> crate::Result<String> {
        Ok(String::new())
    }

    pub fn export_latest_stroke_fragment(&self) -> crate::Result<Option<StrokeFragment>> {
        Ok(None)
    }
}
