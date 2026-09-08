'use strict';

var core = require('@tauri-apps/api/core');
var event = require('@tauri-apps/api/event');

function normalizePlacement(placement) {
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
async function showCanvas(config = {}) {
    await core.invoke("plugin:canvas|show_canvas", {
        config: {
            placement: normalizePlacement(config.placement),
        },
    });
}
async function hideCanvas() {
    await core.invoke("plugin:canvas|hide_canvas");
}
async function isAvailable() {
    const response = await core.invoke("plugin:canvas|is_available");
    return response.available;
}
async function activatePen(config = {}) {
    await core.invoke("plugin:canvas|activate_pen", {
        config: {
            tool: config.tool ?? "draw",
            style: config.style ?? "smooth",
            color: config.color ?? "#000000",
            width: config.width ?? 2.0,
            opacity: config.opacity ?? 1.0,
            pressureSensitivity: config.pressureSensitivity ?? 0.8,
            fingerDrawing: config.fingerDrawing ?? false,
        },
    });
}
async function deactivatePen() {
    await core.invoke("plugin:canvas|deactivate_pen");
}
async function clear() {
    await core.invoke("plugin:canvas|clear");
}
async function undo() {
    await core.invoke("plugin:canvas|undo");
}
async function redo() {
    await core.invoke("plugin:canvas|redo");
}
async function getStrokes() {
    return core.invoke("plugin:canvas|get_strokes");
}
async function exportImage(options = {}) {
    return core.invoke("plugin:canvas|export_image", { options });
}
/**
 * Export a committed stroke as a PNG fragment.
 *
 * Pass the `strokeId` from the corresponding `strokeEnded` event to export
 * exactly that stroke — without it the newest committed stroke is exported,
 * which races when two strokes finish in quick succession.
 */
async function exportLatestStrokeFragment(strokeId) {
    return core.invoke("plugin:canvas|export_latest_stroke_fragment", {
        options: { strokeId },
    });
}
/**
 * The webview has painted the committed stroke `strokeId` and starts fading
 * its copy in (linear, `STROKE_FADE_MS`). The overlay answers with the
 * complementary fade-out, so both copies always composite to the original
 * stroke — see `MetalCanvasView` for the maths.
 */
async function beginStrokeFade(strokeId) {
    await core.invoke("plugin:canvas|begin_stroke_fade", { options: { strokeId } });
}
/** The webview's copy jumped to full opacity (e.g. the next stroke landed):
 *  drop the overlay's copy at once. */
async function endStrokeFade(strokeId) {
    await core.invoke("plugin:canvas|end_stroke_fade", { options: { strokeId } });
}
/** Duration of the hand-over cross-fade, identical on both sides. */
const STROKE_FADE_MS = 400;

async function onStrokeStarted(handler) {
    if (isMobilePlatform()) {
        const listener = await core.addPluginListener("canvas", "strokeStarted", handler);
        return async () => {
            await listener.unregister();
        };
    }
    return event.listen("plugin:canvas:strokeStarted", (event) => {
        handler(event.payload);
    });
}
async function onStrokeEnded(handler) {
    if (isMobilePlatform()) {
        const listener = await core.addPluginListener("canvas", "strokeEnded", handler);
        return async () => {
            await listener.unregister();
        };
    }
    return event.listen("plugin:canvas:strokeEnded", (event) => {
        handler(event.payload);
    });
}
async function onStrokesCleared(handler) {
    if (isMobilePlatform()) {
        const listener = await core.addPluginListener("canvas", "strokesCleared", handler);
        return async () => {
            await listener.unregister();
        };
    }
    return event.listen("plugin:canvas:strokesCleared", () => {
        handler();
    });
}
async function onDebug(handler) {
    if (isMobilePlatform()) {
        const listener = await core.addPluginListener("canvas", "debug", handler);
        return async () => {
            await listener.unregister();
        };
    }
    return event.listen("plugin:canvas:debug", (event) => {
        handler(event.payload);
    });
}
async function onEraserStrokeStarted(handler) {
    if (isMobilePlatform()) {
        const listener = await core.addPluginListener("canvas", "eraserStrokeStarted", handler);
        return async () => {
            await listener.unregister();
        };
    }
    return event.listen("plugin:canvas:eraserStrokeStarted", (event) => {
        handler(event.payload);
    });
}
async function onEraserStrokeSampled(handler) {
    if (isMobilePlatform()) {
        const listener = await core.addPluginListener("canvas", "eraserStrokeSampled", handler);
        return async () => {
            await listener.unregister();
        };
    }
    return event.listen("plugin:canvas:eraserStrokeSampled", (event) => {
        handler(event.payload);
    });
}
async function onEraserStrokeEnded(handler) {
    if (isMobilePlatform()) {
        const listener = await core.addPluginListener("canvas", "eraserStrokeEnded", handler);
        return async () => {
            await listener.unregister();
        };
    }
    return event.listen("plugin:canvas:eraserStrokeEnded", (event) => {
        handler(event.payload);
    });
}
function isMobilePlatform() {
    const w = window;
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

exports.STROKE_FADE_MS = STROKE_FADE_MS;
exports.activatePen = activatePen;
exports.beginStrokeFade = beginStrokeFade;
exports.clear = clear;
exports.deactivatePen = deactivatePen;
exports.endStrokeFade = endStrokeFade;
exports.exportImage = exportImage;
exports.exportLatestStrokeFragment = exportLatestStrokeFragment;
exports.getStrokes = getStrokes;
exports.hideCanvas = hideCanvas;
exports.isAvailable = isAvailable;
exports.onDebug = onDebug;
exports.onEraserStrokeEnded = onEraserStrokeEnded;
exports.onEraserStrokeSampled = onEraserStrokeSampled;
exports.onEraserStrokeStarted = onEraserStrokeStarted;
exports.onStrokeEnded = onStrokeEnded;
exports.onStrokeStarted = onStrokeStarted;
exports.onStrokesCleared = onStrokesCleared;
exports.redo = redo;
exports.showCanvas = showCanvas;
exports.undo = undo;
//# sourceMappingURL=index.cjs.map
