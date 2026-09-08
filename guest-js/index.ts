import { addPluginListener, invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export interface AvailabilityResponse {
  available: boolean;
  reason?: string | null;
}

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type CanvasPlacement =
  | "fullscreen"
  | { bottom: string }
  | { top: string }
  | { x: number; y: number; width: number; height: number; unit?: "percent" | "px" };

export interface CanvasConfig {
  placement?: CanvasPlacement;
}

/**
 * Who renders a drawing stroke.
 *
 * - `native` (default): the Metal overlay draws the in-progress stroke,
 *   stores it and exports it as a PNG fragment on request
 *   (`exportLatestStrokeFragment`).
 * - `forward`: nothing is drawn or stored natively. Every touch update
 *   arrives as a `strokeSampled` event (real samples plus UIKit's current
 *   prediction) and `strokeEnded` carries `forwarded: true`; the webview
 *   renders the stroke itself. Native undo/redo/export have nothing to
 *   work on in this mode.
 */
export type StrokeRendering = "native" | "forward";

export interface PenConfig {
  tool?: "draw" | "erase";
  style?: "smooth" | "marker" | "pencil";
  color?: string;
  width?: number;
  opacity?: number;
  pressureSensitivity?: number;
  /** Whether direct (finger / capacitive stylus) touches draw too.
   *  Apple Pencil always draws. Default: false. */
  fingerDrawing?: boolean;
  /** Default: `"native"`. */
  strokeRendering?: StrokeRendering;
}

export interface StrokePoint {
  /** Percent of the drawing rect (0..100). */
  x: number;
  y: number;
  /** 0..1 (0.5 for touches without force). */
  pressure: number;
  /** Radians. */
  altitude: number;
  azimuth: number;
  /** Apple Pencil Pro barrel roll in radians (0 otherwise). Only present on
   *  sampled events (`strokeSampled`, `eraserStrokeSampled`). */
  roll?: number;
  /** Seconds since boot (`UITouch.timestamp`). */
  timestamp: number;
}

export interface Stroke {
  id: string;
  points: StrokePoint[];
  color: string;
  baseWidth: number;
  boundingBox: Rect;
}

export interface StrokeStartEvent {
  strokeId: string;
}

export interface StrokeEndEvent {
  strokeId: string;
  /** Empty for forwarded strokes (the webview already has every sample). */
  points: StrokePoint[];
  boundingBox: Rect;
  /** True when the stroke was rendered by the webview (`strokeRendering:
   *  "forward"`) — there is no native fragment to export. */
  forwarded?: boolean;
  /** Forwarded strokes only: discarded (second finger, pen mode switched
   *  mid-stroke) — drop the live stroke instead of committing it. */
  cancelled?: boolean;
}

/** `strokeRendering: "forward"` only: one touch update of the in-progress
 *  stroke. `points` are new real samples to append; `predicted` is UIKit's
 *  current guess of the next few positions — draw them after the real
 *  samples and replace them wholesale on the next event. */
export interface StrokeSampledEvent {
  strokeId: string;
  points: StrokePoint[];
  predicted: StrokePoint[];
  /** Seconds since boot when the plugin emitted the event (same clock as
   *  the sample timestamps). */
  sentAt: number;
}

export interface EraserStrokeStartEvent {
  strokeId: string;
  baseWidth: number;
  pressureSensitivity: number;
}

export interface EraserStrokeSampledEvent {
  strokeId: string;
  points: StrokePoint[];
  baseWidth: number;
  pressureSensitivity: number;
}

export interface EraserStrokeEndEvent {
  strokeId: string;
  /** True when the stroke was discarded (e.g. a second finger turned the
   *  gesture into zoom/pan) — drop the preview instead of committing it. */
  cancelled?: boolean;
}

export interface ExportOptions {
  includeBackground?: boolean;
}

export interface StrokeFragment {
  strokeId: string;
  boundingBox: Rect;
  imageData: string;
}

export interface DebugEvent {
  source: string;
  message: string;
}

function normalizePlacement(placement?: CanvasPlacement) {
  if (!placement || placement === "fullscreen") {
    return "fullscreen";
  }
  if ("x" in placement) {
    if (placement.unit === "px") {
      const { unit: _unit, ...viewport } = placement;
      return { viewport };
    }
    return { region: placement };
  }
  if ("bottom" in placement) {
    return { bottom: placement.bottom };
  }
  return { top: placement.top };
}

export async function showCanvas(config: CanvasConfig = {}): Promise<void> {
  await invoke("plugin:canvas|show_canvas", {
    config: {
      placement: normalizePlacement(config.placement),
    },
  });
}

export async function hideCanvas(): Promise<void> {
  await invoke("plugin:canvas|hide_canvas");
}

export async function isAvailable(): Promise<boolean> {
  const response = await invoke<AvailabilityResponse>("plugin:canvas|is_available");
  return response.available;
}

export async function activatePen(config: PenConfig = {}): Promise<void> {
  await invoke("plugin:canvas|activate_pen", {
    config: {
      tool: config.tool ?? "draw",
      style: config.style ?? "smooth",
      color: config.color ?? "#000000",
      width: config.width ?? 2.0,
      opacity: config.opacity ?? 1.0,
      pressureSensitivity: config.pressureSensitivity ?? 0.8,
      fingerDrawing: config.fingerDrawing ?? false,
      strokeRendering: config.strokeRendering ?? "native",
    },
  });
}

export async function deactivatePen(): Promise<void> {
  await invoke("plugin:canvas|deactivate_pen");
}

export async function clear(): Promise<void> {
  await invoke("plugin:canvas|clear");
}

export async function undo(): Promise<void> {
  await invoke("plugin:canvas|undo");
}

export async function redo(): Promise<void> {
  await invoke("plugin:canvas|redo");
}

export async function getStrokes(): Promise<Stroke[]> {
  return invoke<Stroke[]>("plugin:canvas|get_strokes");
}

export async function exportImage(options: ExportOptions = {}): Promise<string> {
  return invoke<string>("plugin:canvas|export_image", { options });
}

/**
 * Export a committed stroke as a PNG fragment.
 *
 * Pass the `strokeId` from the corresponding `strokeEnded` event to export
 * exactly that stroke — without it the newest committed stroke is exported,
 * which races when two strokes finish in quick succession.
 */
export async function exportLatestStrokeFragment(strokeId?: string): Promise<StrokeFragment | null> {
  return invoke<StrokeFragment | null>("plugin:canvas|export_latest_stroke_fragment", {
    options: { strokeId },
  });
}

export async function onStrokeStarted(
  handler: (event: StrokeStartEvent) => void,
): Promise<UnlistenFn> {
  if (isMobilePlatform()) {
    const listener = await addPluginListener<StrokeStartEvent>("canvas", "strokeStarted", handler);
    return async () => {
      await listener.unregister();
    };
  }

  return listen<StrokeStartEvent>("plugin:canvas:strokeStarted", (event) => {
    handler(event.payload);
  });
}

export async function onStrokeEnded(
  handler: (event: StrokeEndEvent) => void,
): Promise<UnlistenFn> {
  if (isMobilePlatform()) {
    const listener = await addPluginListener<StrokeEndEvent>("canvas", "strokeEnded", handler);
    return async () => {
      await listener.unregister();
    };
  }

  return listen<StrokeEndEvent>("plugin:canvas:strokeEnded", (event) => {
    handler(event.payload);
  });
}

export async function onStrokeSampled(
  handler: (event: StrokeSampledEvent) => void,
): Promise<UnlistenFn> {
  if (isMobilePlatform()) {
    const listener = await addPluginListener<StrokeSampledEvent>("canvas", "strokeSampled", handler);
    return async () => {
      await listener.unregister();
    };
  }

  return listen<StrokeSampledEvent>("plugin:canvas:strokeSampled", (event) => {
    handler(event.payload);
  });
}

export async function onStrokesCleared(handler: () => void): Promise<UnlistenFn> {
  if (isMobilePlatform()) {
    const listener = await addPluginListener("canvas", "strokesCleared", handler);
    return async () => {
      await listener.unregister();
    };
  }

  return listen("plugin:canvas:strokesCleared", () => {
    handler();
  });
}

export async function onDebug(
  handler: (event: DebugEvent) => void,
): Promise<UnlistenFn> {
  if (isMobilePlatform()) {
    const listener = await addPluginListener<DebugEvent>("canvas", "debug", handler);
    return async () => {
      await listener.unregister();
    };
  }

  return listen<DebugEvent>("plugin:canvas:debug", (event) => {
    handler(event.payload);
  });
}

export async function onEraserStrokeStarted(
  handler: (event: EraserStrokeStartEvent) => void,
): Promise<UnlistenFn> {
  if (isMobilePlatform()) {
    const listener = await addPluginListener<EraserStrokeStartEvent>("canvas", "eraserStrokeStarted", handler);
    return async () => {
      await listener.unregister();
    };
  }

  return listen<EraserStrokeStartEvent>("plugin:canvas:eraserStrokeStarted", (event) => {
    handler(event.payload);
  });
}

export async function onEraserStrokeSampled(
  handler: (event: EraserStrokeSampledEvent) => void,
): Promise<UnlistenFn> {
  if (isMobilePlatform()) {
    const listener = await addPluginListener<EraserStrokeSampledEvent>("canvas", "eraserStrokeSampled", handler);
    return async () => {
      await listener.unregister();
    };
  }

  return listen<EraserStrokeSampledEvent>("plugin:canvas:eraserStrokeSampled", (event) => {
    handler(event.payload);
  });
}

export async function onEraserStrokeEnded(
  handler: (event: EraserStrokeEndEvent) => void,
): Promise<UnlistenFn> {
  if (isMobilePlatform()) {
    const listener = await addPluginListener<EraserStrokeEndEvent>("canvas", "eraserStrokeEnded", handler);
    return async () => {
      await listener.unregister();
    };
  }

  return listen<EraserStrokeEndEvent>("plugin:canvas:eraserStrokeEnded", (event) => {
    handler(event.payload);
  });
}

function isMobilePlatform(): boolean {
  const w = window as typeof window & {
    __TAURI_INTERNALS__?: { plugins?: { os?: { platform?: string } } };
    Android?: unknown;
    webkit?: { messageHandlers?: unknown };
  };

  const platform = w.__TAURI_INTERNALS__?.plugins?.os?.platform;
  if (platform === "android" || platform === "ios") {
    return true;
  }

  if (w.Android) {
    return true;
  }

  if (w.webkit?.messageHandlers) {
    if (navigator.maxTouchPoints > 1) {
      return true;
    }
    const ua = navigator.userAgent.toLowerCase();
    if (ua.includes("iphone") || ua.includes("ipod")) {
      return true;
    }
  }

  return false;
}
