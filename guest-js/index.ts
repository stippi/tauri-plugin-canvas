import { invoke } from "@tauri-apps/api/core";
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
  | { x: number; y: number; width: number; height: number };

export interface CanvasConfig {
  placement?: CanvasPlacement;
}

export interface PenConfig {
  color?: string;
  width?: number;
  opacity?: number;
  pressureSensitivity?: number;
}

export interface StrokePoint {
  x: number;
  y: number;
  pressure: number;
  altitude: number;
  azimuth: number;
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
  points: StrokePoint[];
  boundingBox: Rect;
}

export interface ExportOptions {
  includeBackground?: boolean;
}

function normalizePlacement(placement?: CanvasPlacement) {
  if (!placement || placement === "fullscreen") {
    return "fullscreen";
  }
  if ("x" in placement) {
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
      color: config.color ?? "#000000",
      width: config.width ?? 2.0,
      opacity: config.opacity ?? 1.0,
      pressureSensitivity: config.pressureSensitivity ?? 0.8,
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

export async function onStrokeStarted(
  handler: (event: StrokeStartEvent) => void,
): Promise<UnlistenFn> {
  return listen<StrokeStartEvent>("plugin:canvas:stroke_started", (event) => {
    handler(event.payload);
  });
}

export async function onStrokeEnded(
  handler: (event: StrokeEndEvent) => void,
): Promise<UnlistenFn> {
  return listen<StrokeEndEvent>("plugin:canvas:stroke_ended", (event) => {
    handler(event.payload);
  });
}

export async function onStrokesCleared(handler: () => void): Promise<UnlistenFn> {
  return listen("plugin:canvas:strokes_cleared", () => {
    handler();
  });
}
