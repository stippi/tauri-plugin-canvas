import { type UnlistenFn } from "@tauri-apps/api/event";
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
export type CanvasPlacement = "fullscreen" | {
    bottom: string;
} | {
    top: string;
} | {
    x: number;
    y: number;
    width: number;
    height: number;
    unit?: "percent" | "px";
};
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
export declare function showCanvas(config?: CanvasConfig): Promise<void>;
export declare function hideCanvas(): Promise<void>;
export declare function isAvailable(): Promise<boolean>;
export declare function activatePen(config?: PenConfig): Promise<void>;
export declare function deactivatePen(): Promise<void>;
export declare function clear(): Promise<void>;
export declare function undo(): Promise<void>;
export declare function redo(): Promise<void>;
export declare function getStrokes(): Promise<Stroke[]>;
export declare function exportImage(options?: ExportOptions): Promise<string>;
/**
 * Export a committed stroke as a PNG fragment.
 *
 * Pass the `strokeId` from the corresponding `strokeEnded` event to export
 * exactly that stroke — without it the newest committed stroke is exported,
 * which races when two strokes finish in quick succession.
 */
export declare function exportLatestStrokeFragment(strokeId?: string): Promise<StrokeFragment | null>;
/**
 * Native rendering only: the webview has painted the committed stroke
 * `strokeId` and starts fading its copy in (linear, `STROKE_FADE_MS`). The
 * overlay answers with the complementary fade-out, so both copies always
 * composite to the original stroke — see `MetalCanvasView` for the maths.
 */
export declare function beginStrokeFade(strokeId: string): Promise<void>;
/** The webview's copy jumped to full opacity (e.g. the next stroke landed):
 *  drop the overlay's copy at once. */
export declare function endStrokeFade(strokeId: string): Promise<void>;
/** Duration of the hand-over cross-fade, identical on both sides. */
export declare const STROKE_FADE_MS = 400;
export declare function onStrokeStarted(handler: (event: StrokeStartEvent) => void): Promise<UnlistenFn>;
export declare function onStrokeEnded(handler: (event: StrokeEndEvent) => void): Promise<UnlistenFn>;
export declare function onStrokeSampled(handler: (event: StrokeSampledEvent) => void): Promise<UnlistenFn>;
export declare function onStrokesCleared(handler: () => void): Promise<UnlistenFn>;
export declare function onDebug(handler: (event: DebugEvent) => void): Promise<UnlistenFn>;
export declare function onEraserStrokeStarted(handler: (event: EraserStrokeStartEvent) => void): Promise<UnlistenFn>;
export declare function onEraserStrokeSampled(handler: (event: EraserStrokeSampledEvent) => void): Promise<UnlistenFn>;
export declare function onEraserStrokeEnded(handler: (event: EraserStrokeEndEvent) => void): Promise<UnlistenFn>;
