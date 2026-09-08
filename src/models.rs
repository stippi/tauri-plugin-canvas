use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AvailabilityResponse {
    pub available: bool,
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ViewRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
#[serde(rename_all = "camelCase")]
pub enum CanvasPlacement {
    Fullscreen(String),
    Bottom { bottom: String },
    Top { top: String },
    Region { region: ViewRect },
    Viewport { viewport: ViewRect },
}

impl Default for CanvasPlacement {
    fn default() -> Self {
        Self::Fullscreen("fullscreen".into())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct CanvasConfig {
    #[serde(default)]
    pub placement: CanvasPlacement,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PenTool {
    #[default]
    Draw,
    Erase,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PenStyle {
    #[default]
    Smooth,
    Marker,
    Pencil,
}

/// Who renders a drawing stroke: the native Metal overlay (`Native`, the
/// default: draws, stores, exports PNG fragments) or the webview (`Forward`:
/// the overlay only forwards touch samples as `strokeSampled` events).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum StrokeRendering {
    #[default]
    Native,
    Forward,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PenConfig {
    #[serde(default)]
    pub tool: PenTool,
    #[serde(default)]
    pub style: PenStyle,
    #[serde(default = "default_color")]
    pub color: String,
    #[serde(default = "default_width")]
    pub width: f32,
    #[serde(default = "default_opacity")]
    pub opacity: f32,
    #[serde(default = "default_pressure_sensitivity")]
    pub pressure_sensitivity: f32,
    /// Whether direct (finger / capacitive stylus) touches draw too.
    #[serde(default)]
    pub finger_drawing: bool,
    #[serde(default)]
    pub stroke_rendering: StrokeRendering,
}

impl Default for PenConfig {
    fn default() -> Self {
        Self {
            tool: PenTool::default(),
            style: PenStyle::default(),
            color: default_color(),
            width: default_width(),
            opacity: default_opacity(),
            pressure_sensitivity: default_pressure_sensitivity(),
            finger_drawing: false,
            stroke_rendering: StrokeRendering::default(),
        }
    }
}

fn default_color() -> String {
    "#000000".into()
}

fn default_width() -> f32 {
    2.0
}

fn default_opacity() -> f32 {
    1.0
}

fn default_pressure_sensitivity() -> f32 {
    0.8
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct StrokePoint {
    pub x: f32,
    pub y: f32,
    pub pressure: f32,
    pub altitude: f32,
    pub azimuth: f32,
    pub timestamp: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Stroke {
    pub id: String,
    pub points: Vec<StrokePoint>,
    pub color: String,
    pub base_width: f32,
    pub bounding_box: Rect,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ExportOptions {
    #[serde(default)]
    pub include_background: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ExportStrokeFragmentOptions {
    /// Id of the committed stroke to export. `None` exports the most recent
    /// committed stroke.
    pub stroke_id: Option<String>,
}

/// Which committed stroke's hand-over fade to begin or end.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct StrokeFadeOptions {
    pub stroke_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct StrokeFragment {
    pub stroke_id: String,
    pub bounding_box: Rect,
    pub image_data: String,
}
