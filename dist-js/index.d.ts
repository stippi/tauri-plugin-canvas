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
export declare function onStrokeStarted(handler: (event: StrokeStartEvent) => void): Promise<UnlistenFn>;
export declare function onStrokeEnded(handler: (event: StrokeEndEvent) => void): Promise<UnlistenFn>;
export declare function onStrokesCleared(handler: () => void): Promise<UnlistenFn>;
export declare function onDebug(handler: (event: DebugEvent) => void): Promise<UnlistenFn>;
export declare function onEraserStrokeStarted(handler: (event: EraserStrokeStartEvent) => void): Promise<UnlistenFn>;
export declare function onEraserStrokeSampled(handler: (event: EraserStrokeSampledEvent) => void): Promise<UnlistenFn>;
export declare function onEraserStrokeEnded(handler: (event: EraserStrokeEndEvent) => void): Promise<UnlistenFn>;
