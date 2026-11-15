/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";

const BASE_STYLE_ID = "bigpicker-style";
const SIZE_STYLE_ID = "bigpicker-size-style";
const GRIP_ID = "bigpicker-grip";

const settings = definePluginSettings({
    keepOpen: {
        type: OptionType.BOOLEAN,
        description: "Keep the panel open after picking an emoji (pick several in a row)",
        default: true
    },
    width: {
        type: OptionType.NUMBER,
        description: "Panel width in pixels (0 = Discord default)",
        default: 0,
        onChange: () => refreshLayout()
    },
    height: {
        type: OptionType.NUMBER,
        description: "Panel height in pixels (0 = 72% of the window height)",
        default: 0,
        onChange: () => refreshLayout()
    }
});

const BASE_CSS = `
/* The panel is tall by default instead of 486px */
[class*="drawerSizingWrapper_"] {
    top: auto !important;
    bottom: 0 !important;
    height: 72vh !important;
}

#${GRIP_ID} {
    position: absolute;
    top: 5px;
    left: 5px;
    width: 18px;
    height: 18px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: nwse-resize;
    z-index: 20;
    border-radius: 4px;
    color: var(--text-muted, #b5bac1);
    opacity: .45;
    transition: opacity .12s ease, background-color .12s ease;
    touch-action: none;
}
#${GRIP_ID}:hover { opacity: 1; background-color: var(--background-mod-normal, rgba(255, 255, 255, .09)); }
#${GRIP_ID}:active { opacity: 1; }
#${GRIP_ID} svg { width: 12px; height: 12px; pointer-events: none; }
`;

let baseStyle: HTMLStyleElement | null = null;
let sizeStyle: HTMLStyleElement | null = null;
let grip: HTMLDivElement | null = null;
let observer: MutationObserver | null = null;
let drag: { startX: number; startY: number; w: number; h: number } | null = null;

const clampW = (v: number) => Math.max(320, Math.min(v, window.innerWidth - 120));
const clampH = (v: number) => Math.max(260, Math.min(v, window.innerHeight - 110));

/** Size lives in a separate <style> so Discord's inline styles don't wipe it */
function updateSizeCss(w = settings.store.width, h = settings.store.height) {
    if (!sizeStyle) return;

    const rules: string[] = [];
    if (w > 0) rules.push(`width: ${Math.round(clampW(w))}px !important;`);
    if (h > 0) rules.push(`height: ${Math.round(clampH(h))}px !important;`);

    sizeStyle.textContent = rules.length
        ? `[class*="drawerSizingWrapper_"] { ${rules.join(" ")} }`
        : "";
}

function setSize(w: number, h: number) {
    settings.store.width = Math.round(w);
    settings.store.height = Math.round(h);
    updateSizeCss();
}

const onWindowResize = () => {
    // while dragging, the size comes from the drag; settings are still stale
    if (!drag) updateSizeCss();
};

let nudgeTimer: ReturnType<typeof setTimeout> | null = null;
let lastNudgeAt = 0;

/**
 * Discord only recalculates the emoji grid when the window is resized,
 * so after changing the panel size we dispatch resize — otherwise emojis
 * keep the old column count and don't fill the full width.
 */
function nudgeGrid(force = false) {
    const run = () => {
        nudgeTimer = null;
        lastNudgeAt = performance.now();
        window.dispatchEvent(new Event("resize"));
    };

    if (force) {
        if (nudgeTimer) {
            clearTimeout(nudgeTimer);
            nudgeTimer = null;
        }
        run();
        return;
    }

    // Discord recalculates the grid ~350ms after resize,
    // so while dragging we dispatch the event at most every 350ms
    const wait = 350 - (performance.now() - lastNudgeAt);
    if (wait <= 0) run();
    else if (!nudgeTimer) nudgeTimer = setTimeout(run, wait);
}

function refreshLayout() {
    updateSizeCss();
    nudgeGrid(true);
}

function onGripDown(e: PointerEvent) {
    if (e.button !== 0 || !grip) return;
    const drawer = grip.parentElement;
    if (!drawer) return;

    const r = drawer.getBoundingClientRect();
    drag = { startX: e.clientX, startY: e.clientY, w: r.width, h: r.height };
    grip.style.opacity = "1";
    e.preventDefault();
    e.stopPropagation();
}

function onGripDblClick(e: MouseEvent) {
    e.preventDefault();
    e.stopPropagation();
    setSize(0, 0);
}

function onMove(e: PointerEvent) {
    if (!drag) return;

    // incrementally, so settings are touched only once — at the end
    drag.w = clampW(drag.w + (drag.startX - e.clientX));
    drag.h = clampH(drag.h + (drag.startY - e.clientY));
    drag.startX = e.clientX;
    drag.startY = e.clientY;

    updateSizeCss(drag.w, drag.h);
    nudgeGrid();
    e.preventDefault();
}

function onUp() {
    if (!drag) return;

    setSize(drag.w, drag.h);
    drag = null;
    if (grip) grip.style.opacity = "";
}

// Discord's native width resize handle should keep working
function onAnyPointerDown(e: PointerEvent) {
    if (settings.store.width > 0 && e.target instanceof Element && e.target.closest('[class*="resizeHandle_"]'))
        setSize(0, settings.store.height);
}

// Discord closes the panel after an emoji click unless Shift is held.
// We set the flag on the event — the panel stays open and the search isn't reset.
function onEmojiPick(e: MouseEvent) {
    if (!settings.store.keepOpen) return;

    const target = e.target;
    if (!(target instanceof Element) || !target.closest('[class*="emojiItem"]')) return;

    Object.defineProperty(e, "shiftKey", { value: true, configurable: true });
}

function mount() {
    const drawer = document.querySelector('[class*="drawerSizingWrapper_"]');
    if (drawer && grip && grip.parentElement !== drawer) drawer.appendChild(grip);
}

export default definePlugin({
    name: "BigPicker",
    description: "Makes the emoji/GIF/sticker panel large and resizable in every direction",
    authors: [{ name: "local", id: 0n }],
    tags: ["Emotes", "Customisation"],
    enabledByDefault: true,
    settings,

    start() {
        baseStyle = document.createElement("style");
        baseStyle.id = BASE_STYLE_ID;
        baseStyle.textContent = BASE_CSS;
        document.head.appendChild(baseStyle);

        sizeStyle = document.createElement("style");
        sizeStyle.id = SIZE_STYLE_ID;
        document.head.appendChild(sizeStyle);
        updateSizeCss();

        grip = document.createElement("div");
        grip.id = GRIP_ID;
        grip.title = "Drag to resize the panel • double-click to reset";
        grip.innerHTML = '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M2.6 9.4 L9.4 2.6"/><path d="M2.6 4.9 L4.9 2.6"/><path d="M7.1 9.4 L9.4 7.1"/></svg>';

        grip.addEventListener("pointerdown", onGripDown);
        grip.addEventListener("dblclick", onGripDblClick);
        window.addEventListener("pointermove", onMove, true);
        window.addEventListener("pointerup", onUp, true);
        window.addEventListener("pointercancel", onUp, true);
        window.addEventListener("resize", onWindowResize);
        document.addEventListener("pointerdown", onAnyPointerDown, true);
        document.addEventListener("click", onEmojiPick, true);

        observer = new MutationObserver(() => {
            if (grip && !grip.isConnected) mount();
        });
        observer.observe(document.body, { childList: true, subtree: true });
        mount();
    },

    stop() {
        observer?.disconnect();
        observer = null;

        if (nudgeTimer) {
            clearTimeout(nudgeTimer);
            nudgeTimer = null;
        }

        grip?.removeEventListener("pointerdown", onGripDown);
        grip?.removeEventListener("dblclick", onGripDblClick);
        window.removeEventListener("pointermove", onMove, true);
        window.removeEventListener("pointerup", onUp, true);
        window.removeEventListener("pointercancel", onUp, true);
        window.removeEventListener("resize", onWindowResize);
        document.removeEventListener("pointerdown", onAnyPointerDown, true);
        document.removeEventListener("click", onEmojiPick, true);

        grip?.remove();
        grip = null;
        baseStyle?.remove();
        baseStyle = null;
        sizeStyle?.remove();
        sizeStyle = null;
    }
});