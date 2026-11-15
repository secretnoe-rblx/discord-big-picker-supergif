#requires -version 5.1
<#
    BigPicker — a large, resizable GIF/emoji panel for Discord.
    The script installs Vencord (the mod loader), adds the BigPicker and SuperGifs plugins, builds everything and patches Discord.
#>

param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Vencord",
    [switch]$SkipDiscordPatch,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Say($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "  [ok] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Fail($msg) {
    Write-Host ""
    Write-Host "  [error] $msg" -ForegroundColor Red
    Write-Host ""
    if (-not $NoPause) { Read-Host "Press Enter to close" }
    exit 1
}

# runs an external program and returns its exit code (stderr does not crash the script)
function Run($exe, [string[]]$arguments) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $exe @arguments | Out-Host
        return $LASTEXITCODE
    } catch {
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        return 1
    } finally { $ErrorActionPreference = $prev }
}

# corepack is not always in PATH (or missing entirely) — find a working pnpm runner
function Resolve-Pnpm {
    Refresh-Path

    if (Get-Command corepack -ErrorAction SilentlyContinue) {
        return @{ Exe = "corepack"; Args = @("pnpm") }
    }

    $corepackCmd = Join-Path $env:ProgramFiles "nodejs\corepack.cmd"
    if (Test-Path $corepackCmd) {
        return @{ Exe = $corepackCmd; Args = @() }
    }

    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
        return @{ Exe = "pnpm"; Args = @() }
    }

    if (Get-Command npx -ErrorAction SilentlyContinue) {
        return @{ Exe = "npx"; Args = @("--yes", "pnpm@12.15.0") }
    }

    Fail "pnpm was not found. Install Node.js LTS from https://nodejs.org/ and run the installer again."
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

function Test-NodeOk {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    try {
        $ver = (& node -v) -replace "^v", ""
        return ([int]($ver.Split(".")[0]) -ge 22)
    } catch { return $false }
}

function Ensure-Tool($wingetId, $displayName, $command, $manualUrl) {
    Refresh-Path
    if (Get-Command $command -ErrorAction SilentlyContinue) {
        Ok "$displayName is already installed"
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail "$displayName was not found. Install it manually: $manualUrl — then run the installer again."
    }

    Say "Installing $displayName (a UAC prompt may appear — click Yes)"
    Run "winget" @("install", "--id", $wingetId, "-e", "--accept-source-agreements", "--accept-package-agreements") | Out-Null
    Refresh-Path

    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$displayName still did not appear. Install it manually: $manualUrl — then run the installer again."
    }
    Ok "$displayName installed"
}

$pluginSource = @'
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
'@

$superGifsPluginSource = @'
/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import * as DataStore from "@api/DataStore";
import { definePluginSettings } from "@api/Settings";
import { insertTextIntoChatInputBox, sendMessage } from "@utils/discord";
import definePlugin, { OptionType } from "@utils/types";
import { ExpressionPickerStore, FluxDispatcher, GIFPickerViewStore, MessageActions, PendingReplyStore, SelectedChannelStore, showToast } from "@webpack/common";

const STORE_KEY = "superGifs_categories_v1";
const STYLE_ID = "supergifs-style";
const FAV_ID = "favorites";

interface SavedGif {
    id: string;
    /** Media shown in the grid (may be .webp/.mp4) */
    src: string;
    /** Fallback if src fails to load */
    gifSrc?: string;
    /** Link that is inserted into chat */
    url: string;
    width: number;
    height: number;
}

interface SuperCategory {
    id: string;
    name: string;
    gifs: SavedGif[];
}

const settings = definePluginSettings({
    hideStandardCategories: {
        type: OptionType.BOOLEAN,
        description: "Hide all standard GIF categories (except Favorites)",
        default: true,
        onChange: () => refreshHiddenTiles()
    },
    hideCategories: {
        type: OptionType.STRING,
        description: "Also hide categories by name (comma-separated)",
        default: "",
        onChange: () => refreshHiddenTiles()
    }
});

const CSS = `
.sg-star {
    position: absolute;
    right: 6px;
    top: 50%;
    transform: translateY(-50%);
    display: flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    padding: 0;
    border: none;
    border-radius: 6px;
    background: transparent;
    color: var(--text-muted, #b5bac1);
    cursor: pointer;
    z-index: 5;
    transition: color .12s ease, background-color .12s ease;
}
.sg-star:hover { color: var(--brand-experiment, #5865f2); background: var(--background-mod-normal, rgba(255,255,255,.08)); }
.sg-star.sg-active { color: var(--brand-experiment, #5865f2); }
.sg-star svg { width: 16px; height: 16px; pointer-events: none; }

.sg-popup {
    position: absolute;
    z-index: 40;
    display: none;
    width: 280px;
    max-height: 60%;
    overflow-y: auto;
    padding: 6px;
    border-radius: 8px;
    background: var(--background-floating, #111214);
    box-shadow: 0 8px 24px rgba(0,0,0,.45);
    border: 1px solid var(--background-modifier-accent, rgba(255,255,255,.06));
    font-size: 14px;
    color: var(--text-normal, #dbdee1);
    box-sizing: border-box;
}
.sg-row {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px;
    border-radius: 5px;
    cursor: pointer;
    user-select: none;
}
.sg-row:hover { background: var(--background-mod-subtle, rgba(255,255,255,.06)); }
.sg-row-name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.sg-count { font-size: 12px; color: var(--text-muted, #b5bac1); }
.sg-x {
    display: flex; align-items: center; justify-content: center;
    width: 20px; height: 20px; padding: 0; border: none; border-radius: 4px;
    background: transparent; color: var(--text-muted, #b5bac1);
    cursor: pointer; font-size: 14px; line-height: 1;
}
.sg-x:hover { background: var(--status-danger, #da373c); color: #fff; }
.sg-new { display: flex; gap: 6px; padding: 8px; }
.sg-input {
    flex: 1; min-width: 0; padding: 6px 8px; border-radius: 4px;
    border: 1px solid var(--background-modifier-accent, rgba(255,255,255,.12));
    background: var(--input-background, #1e1f22);
    color: var(--text-normal, #dbdee1);
    font-size: 14px; outline: none;
}
.sg-input:focus { border-color: var(--brand-experiment, #5865f2); }
.sg-btn {
    padding: 6px 10px; border: none; border-radius: 4px; cursor: pointer;
    background: var(--brand-experiment, #5865f2); color: #fff; font-size: 13px;
}
.sg-btn:hover { filter: brightness(1.1); }
.sg-btn.sg-plain { background: var(--background-mod-normal, rgba(255,255,255,.08)); color: var(--text-normal, #dbdee1); }
.sg-back {
    flex: 0 0 auto;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    padding: 0;
    border: none;
    border-radius: 4px;
    background: transparent;
    color: var(--text-default, #f2f3f5);
    cursor: pointer;
    transition: background-color .12s ease;
}
.sg-back:hover { background: var(--background-mod-normal, rgba(255,255,255,.08)); }
.sg-back svg { pointer-events: none; }

/* Discord's own favorite star: left instead of right */
[class*="result_"] [class*="gifFavoriteButton"],
[class*="result_"] [class*="favButton_"] {
    left: 4px !important;
    right: auto !important;
}
.sg-sep { height: 1px; margin: 4px 6px; background: var(--background-modifier-accent, rgba(255,255,255,.06)); }

.sg-overlay {
    position: absolute; left: 0; right: 0; bottom: 0; z-index: 30;
    display: none; flex-direction: column;
    background: var(--background-surface-high, var(--background-primary, #2b2d31));
    color: var(--text-default, var(--text-normal, #f2f3f5));
    box-sizing: border-box;
}
.sg-overlay-head {
    display: flex; align-items: center; gap: 8px;
    padding: 8px 12px; flex: 0 0 auto;
    border-bottom: 1px solid var(--border-subtle, rgba(255,255,255,.06));
}
.sg-title { flex: 1; font-weight: 600; color: var(--text-strong, var(--text-default, #f2f3f5)); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.sg-body { flex: 1 1 auto; overflow-y: auto; padding: 12px; }
.sg-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 8px; }
.sg-tile {
    position: relative; padding: 0; border: none; border-radius: 6px;
    overflow: hidden; cursor: pointer; background: var(--background-secondary, #2b2d31);
    height: 110px; display: block;
}
.sg-tile img, .sg-tile video { width: 100%; height: 100%; object-fit: cover; display: block; }
.sg-tile:hover { outline: 2px solid var(--brand-experiment, #5865f2); outline-offset: -2px; }
.sg-del {
    position: absolute; top: 4px; left: 4px; width: 22px; height: 22px;
    display: none; align-items: center; justify-content: center;
    border: none; border-radius: 50%; cursor: pointer;
    background: rgba(0,0,0,.65); color: #fff; font-size: 13px; line-height: 1;
}
.sg-tile:hover .sg-del { display: flex; }
.sg-empty { color: var(--text-muted, #b5bac1); font-size: 14px; text-align: center; padding: 24px 12px; line-height: 1.5; white-space: pre-line; }

.sg-banner {
    position: absolute; left: 12px; right: 12px; z-index: 45;
    display: none; align-items: center; gap: 8px;
    padding: 8px 10px; border-radius: 8px;
    background: var(--brand-experiment, #5865f2); color: #fff;
    font-size: 13px; box-shadow: 0 6px 18px rgba(0,0,0,.4);
}
.sg-banner.sg-show { display: flex; }
.sg-banner-text { flex: 1; line-height: 1.35; }
.sg-banner .sg-btn { background: rgba(255,255,255,.2); }

.sg-cat-tile {
    position: absolute;
    box-sizing: border-box;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0;
    border: none;
    border-radius: 8px;
    overflow: hidden;
    background-color: var(--background-secondary, #2b2d31);
    background-size: cover;
    background-position: center;
    color: #fff;
    cursor: pointer;
    font-family: var(--font-primary, sans-serif);
}
.sg-cat-tile::before {
    content: "";
    position: absolute;
    inset: 0;
    z-index: 1;
    background: linear-gradient(180deg, rgba(0,0,0,.1) 35%, rgba(0,0,0,.6));
    pointer-events: none;
}
.sg-cat-tile:hover { outline: 2px solid var(--brand-experiment, #5865f2); outline-offset: -2px; }
.sg-cat-preview {
    position: absolute;
    inset: 0;
    z-index: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
    pointer-events: none;
}
.sg-cat-name {
    position: relative;
    z-index: 2;
    max-width: 92%;
    font-size: 14px;
    font-weight: 600;
    line-height: 1.25;
    text-align: center;
    text-shadow: 0 1px 3px rgba(0,0,0,.85);
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    word-break: break-word;
}
.sg-cat-count {
    position: absolute;
    top: 6px;
    right: 8px;
    z-index: 2;
    font-size: 11px;
    font-weight: 600;
    color: rgba(255,255,255,.9);
    background: rgba(0,0,0,.45);
    padding: 1px 6px;
    border-radius: 8px;
}
.sg-cat-del {
    position: absolute;
    top: 6px;
    left: 8px;
    z-index: 2;
    width: 22px;
    height: 22px;
    padding: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    border: none;
    border-radius: 50%;
    background: rgba(0,0,0,.55);
    color: #fff;
    font-size: 12px;
    line-height: 1;
    cursor: pointer;
    opacity: .65;
    transition: opacity .12s ease, background-color .12s ease;
}
.sg-cat-del:hover { opacity: 1; background: var(--status-danger, #da373c); }
.sg-cat-confirm {
    flex-direction: column;
    gap: 6px;
    padding: 8px;
    text-align: center;
}
.sg-cat-confirm-btns {
    position: relative;
    z-index: 2;
    display: flex;
    gap: 6px;
}
.sg-cat-plus { background-image: none; background-color: var(--background-secondary-alt, #232428); border: 1px dashed rgba(255,255,255,.18); }
.sg-cat-plus::before { background: none; }
.sg-cat-plus .sg-cat-name { color: var(--text-muted, #b5bac1); text-shadow: none; font-weight: 500; }
.sg-cat-input {
    position: relative;
    z-index: 2;
    width: 100%;
    height: 100%;
    padding: 8px;
    border: none;
    outline: none;
    background: var(--background-secondary-alt, #232428);
    color: var(--text-normal, #dbdee1);
    font-size: 14px;
    text-align: center;
    box-sizing: border-box;
}

.sg-msg-add {
    position: absolute;
    top: 6px;
    right: 6px;
    left: auto;
    z-index: 10;
    width: 32px;
    height: 32px;
    box-sizing: border-box;
    padding: 6px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 5px;
    background: #000;
    color: #fff;
    font-size: 20px;
    line-height: 1;
    font-weight: 500;
    cursor: pointer;
    opacity: 0;
    pointer-events: none;
    transition: opacity .12s ease, background-color .12s ease;
    user-select: none;
}
.sg-media-host:hover > .sg-msg-add,
*:hover > .sg-msg-add,
.sg-msg-add:hover {
    opacity: .85;
    pointer-events: auto;
}
.sg-msg-add:hover { opacity: 1; background: var(--brand-experiment, #5865f2); }
.sg-msg-add.sg-floating {
    position: fixed;
    z-index: 99990;
    opacity: .85;
    pointer-events: auto;
}

.sg-chat-menu {
    position: fixed;
    z-index: 999999;
    width: 240px;
    max-height: 340px;
}

body.sg-add-active .sg-overlay { display: none !important; }
`;

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls?: string, text?: string) {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
}

let drawer: HTMLElement | null = null;
let star: HTMLButtonElement | null = null;
let popup: HTMLDivElement | null = null;
let overlay: HTMLDivElement | null = null;
let banner: HTMLDivElement | null = null;
let observer: MutationObserver | null = null;
let resizeObserver: ResizeObserver | null = null;
let drawerObserver: MutationObserver | null = null;
let ensureTimer: ReturnType<typeof setInterval> | null = null;
let drawerOpenedAt = 0;
let maskedGrid: HTMLElement | null = null;
let maskTimer: ReturnType<typeof setTimeout> | null = null;

let categories: SuperCategory[] = [];
let openCatId: string | null = null;
let addMode: string | null = null;
let newCatInputOpen = false;
let renameCatId: string | null = null;

const defaultCategories = (): SuperCategory[] => [
    { id: FAV_ID, name: "Super Favorites", gifs: [] }
];

function normalize(u?: string) {
    return (u || "").split("?")[0].toLowerCase();
}

function isVideo(url?: string) {
    return !!url && /\.(mp4|webm)(\?|$)/i.test(url);
}

/** Discord proxies media: .../external/<sig>/https/host/path -> https://host/path */
function decodeProxy(url: string) {
    const m = /\/external\/[^/]+\/(https?)\/([^?#]+)(\?.*)?$/.exec(url);
    return m ? `${m[1]}://${m[2]}${m[3] ?? ""}` : url;
}

async function loadCategories() {
    try {
        const saved = await DataStore.get<SuperCategory[]>(STORE_KEY);
        categories = Array.isArray(saved) ? saved : defaultCategories();
    } catch {
        categories = defaultCategories();
    }

    const favorites = categories.find(c => c.id === FAV_ID);
    if (favorites?.name === "Супер-избранное") {
        favorites.name = "Super Favorites";
        saveCategories();
    }

    for (const c of categories) {
        if (!Array.isArray(c.gifs)) c.gifs = [];
    }
}

function saveCategories() {
    DataStore.set(STORE_KEY, categories).catch(() => { });
}

function findDrawer() {
    return document.querySelector<HTMLElement>('[class*="drawerSizingWrapper_"]');
}

function findSearchInput(root: HTMLElement | null = drawer) {
    return root?.querySelector<HTMLInputElement>("input[placeholder]") ?? null;
}

function topOffset() {
    const input = findSearchInput();
    if (!drawer || !input) return 64;
    return input.getBoundingClientRect().bottom - drawer.getBoundingClientRect().top + 8;
}

function updatePosition() {
    if (!drawer) return;
    const top = `${topOffset()}px`;

    if (popup) {
        popup.style.top = top;
        popup.style.right = "12px";
    }
    if (overlay) overlay.style.top = top;
    if (banner) banner.style.top = top;
    placeStar();
    clampDrawerHeight();
}

/** Не даём панели уезжать за верх окна, когда поле ввода растёт из-за вложений */
function clampDrawerHeight() {
    if (!drawer) return;

    const rect = drawer.getBoundingClientRect();
    if (rect.height <= 0) return;

    const available = Math.max(240, rect.bottom - 60);
    drawer.style.maxHeight = `${Math.round(available)}px`;
}

/** Keep the star from overlapping the search clear button */
function placeStar() {
    const input = findSearchInput();
    if (!star || !input) return;

    const hasText = input.value.length > 0;
    star.style.right = hasText ? "34px" : "6px";
    input.style.paddingRight = hasText ? "64px" : "36px";
}

/* ---------------------------------------------------------------- */
/*  Categories and adding                                          */
/* ---------------------------------------------------------------- */

const gifKey = (g: SavedGif) => normalize(g.url) || normalize(g.src);

/** Ссылка для отправки: прямые mp4/webm с GIF-провайдеров заменяем на .gif */
function sendUrlFor(gif: SavedGif) {
    const url = gif.url || gif.src;
    if (!url) return url;

    if (!/\.(mp4|webm)([?#]|$)/i.test(url)) return url;

    if (/^https?:\/\/([^/]+\.)?(tenor\.com|giphy\.com|klipy\.com)\//i.test(url)) {
        return url.replace(/\.(mp4|webm)(?=[?#]|$)/i, ".gif");
    }

    return url;
}

function addGif(catId: string, gif: SavedGif) {
    const cat = categories.find(c => c.id === catId);
    if (!cat) return;

    const key = gifKey(gif);
    if (cat.gifs.some(g => gifKey(g) === key || (g.src && normalize(g.src) === normalize(gif.src)))) {
        showToast({ text: `Already in “${cat.name}”` });
        return;
    }

    cat.gifs.unshift(gif);
    saveCategories();

    showToast({ text: `Added to “${cat.name}”`, variant: "success" });

    if (openCatId === catId) renderOverlay();
    renderPopup();
    renderCustomTiles(true);
}

function removeGif(catId: string, gif: SavedGif) {
    const cat = categories.find(c => c.id === catId);
    if (!cat) return;

    cat.gifs = cat.gifs.filter(g => gifKey(g) !== gifKey(gif));
    saveCategories();
    renderOverlay();
    renderPopup();
    renderCustomTiles(true);
}

function createCategory(name: string) {
    const clean = name.trim().slice(0, 40);
    if (!clean) return;

    const cat: SuperCategory = { id: `c${Date.now().toString(36)}`, name: clean, gifs: [] };
    categories.push(cat);
    saveCategories();
    newCatInputOpen = false;
    renderPopup();
    renderCustomTiles(true);
}

function deleteCategory(id: string) {
    categories = categories.filter(c => c.id !== id);
    if (openCatId === id) closeOverlay();
    saveCategories();
    renderPopup();
    renderCustomTiles(true);
}

function renameCategory(id: string, name: string) {
    const cat = categories.find(c => c.id === id);
    if (!cat) return;
    const clean = name.trim().slice(0, 40);
    if (clean) cat.name = clean;
    renameCatId = null;
    saveCategories();
    renderPopup();
    if (openCatId === id) renderOverlay();
    renderCustomTiles(true);
}

/* ---------------------------------------------------------------- */
/*  Category list popup                                            */
/* ---------------------------------------------------------------- */

function openPopup() {
    if (!popup || !drawer) return;
    popup.style.display = "block";
    star?.classList.add("sg-active");
    updatePosition();
    renderPopup();
}

function closePopup() {
    if (!popup) return;
    popup.style.display = "none";
    star?.classList.remove("sg-active");
    newCatInputOpen = false;
    renameCatId = null;
}

function renderPopup() {
    if (!popup) return;
    popup.innerHTML = "";

    for (const cat of categories) {
        if (renameCatId === cat.id) {
            const row = el("div", "sg-new");
            const input = el("input", "sg-input") as HTMLInputElement;
            input.value = cat.name;
            input.maxLength = 40;
            input.addEventListener("keydown", e => {
                if (e.key === "Enter") renameCategory(cat.id, input.value);
                if (e.key === "Escape") { renameCatId = null; renderPopup(); }
            });
            const ok = el("button", "sg-btn", "OK") as HTMLButtonElement;
            ok.addEventListener("click", () => renameCategory(cat.id, input.value));
            row.append(input, ok);
            popup.appendChild(row);
            requestAnimationFrame(() => { input.focus(); input.select(); });
            continue;
        }

        const row = el("div", "sg-row");
        row.title = `${cat.name}  (double-click to rename)`;

        const name = el("span", "sg-row-name", cat.id === FAV_ID ? `★ ${cat.name}` : cat.name);
        const count = el("span", "sg-count", String(cat.gifs.length));
        row.append(name, count);

        row.addEventListener("click", () => {
            closePopup();
            openOverlay(cat.id);
        });

        row.addEventListener("dblclick", e => {
            e.stopPropagation();
            renameCatId = cat.id;
            renderPopup();
        });

        const del = el("button", "sg-x", "✕") as HTMLButtonElement;
        del.title = `Delete “${cat.name}”`;
        del.addEventListener("click", e => {
            e.stopPropagation();
            const sure = el("div", "sg-row");
            const text = el("span", "sg-row-name", `Delete “${cat.name}”?`);
            const yes = el("button", "sg-btn", "Yes") as HTMLButtonElement;
            const no = el("button", "sg-btn sg-plain", "No") as HTMLButtonElement;
            yes.style.background = "var(--status-danger, #da373c)";
            yes.addEventListener("click", ev => { ev.stopPropagation(); deleteCategory(cat.id); });
            no.addEventListener("click", ev => { ev.stopPropagation(); renderPopup(); });
            sure.append(text, yes, no);
            row.replaceWith(sure);
        });
        row.appendChild(del);

        popup.appendChild(row);
    }

    popup.appendChild(el("div", "sg-sep"));

    if (newCatInputOpen) {
        const row = el("div", "sg-new");
        const input = el("input", "sg-input") as HTMLInputElement;
        input.placeholder = "Category name";
        input.maxLength = 40;
        input.addEventListener("keydown", e => {
            if (e.key === "Enter") createCategory(input.value);
            if (e.key === "Escape") { newCatInputOpen = false; renderPopup(); }
        });
        const ok = el("button", "sg-btn", "Create") as HTMLButtonElement;
        ok.addEventListener("click", () => createCategory(input.value));
        row.append(input, ok);
        popup.appendChild(row);
        requestAnimationFrame(() => input.focus());
    } else {
        const add = el("div", "sg-row");
        add.append(el("span", "sg-row-name", "+ New Category"));
        add.addEventListener("click", () => {
            newCatInputOpen = true;
            renameCatId = null;
            renderPopup();
        });
        popup.appendChild(add);
    }
}

/* ---------------------------------------------------------------- */
/*  Category GIF panel                                             */
/* ---------------------------------------------------------------- */

function openOverlay(catId: string) {
    openCatId = catId;
    if (!overlay) return;
    overlay.style.display = "flex";
    updatePosition();
    renderOverlay();
}

function closeOverlay() {
    openCatId = null;
    endAddMode();
    if (overlay) overlay.style.display = "none";
}

function mediaFor(gif: SavedGif) {
    const src = gif.src || gif.url;
    if (isVideo(src)) {
        const v = document.createElement("video");
        v.src = src;
        v.autoplay = true;
        v.loop = true;
        v.muted = true;
        v.playsInline = true;
        return v;
    }

    const img = document.createElement("img");
    img.loading = "lazy";
    img.src = src;
    img.addEventListener("error", () => {
        if (gif.gifSrc && img.src !== gif.gifSrc) img.src = gif.gifSrc;
        else if (gif.url && img.src !== gif.url) img.src = gif.url;
    });
    return img;
}

function renderOverlay() {
    if (!overlay) return;
    const cat = categories.find(c => c.id === openCatId);
    if (!cat) { closeOverlay(); return; }

    overlay.innerHTML = "";

    const head = el("div", "sg-overlay-head");

    const back = el("button", "sg-back", "") as HTMLButtonElement;
    back.type = "button";
    back.title = "Back";
    back.innerHTML = '<svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor"><path d="M19 11H7.83l4.88-4.88L11.3 4.7 4 12l7.3 7.3 1.41-1.42L7.83 13H19v-2z"/></svg>';
    back.addEventListener("click", () => closeOverlay());
    head.appendChild(back);

    head.append(el("span", "sg-title", cat.name));

    const body = el("div", "sg-body");

    if (!cat.gifs.length) {
        body.appendChild(el("div", "sg-empty",
            "Nothing here yet.\nClick the + on any GIF in the picker or in chat — it will be saved here."));
    } else {
        const grid = el("div", "sg-grid");
        for (const gif of cat.gifs) {
            const tile = el("button", "sg-tile") as HTMLButtonElement;
            tile.type = "button";
            tile.title = "Send to chat (Shift-click to send several)";
            tile.appendChild(mediaFor(gif));

            const del = el("button", "sg-del", "✕") as HTMLButtonElement;
            del.type = "button";
            del.title = "Remove from category";
            del.addEventListener("click", e => {
                e.stopPropagation();
                removeGif(cat.id, gif);
            });
            tile.appendChild(del);

            tile.addEventListener("click", e => {
                const url = sendUrlFor(gif);
                if (!url) return;

                const channelId = SelectedChannelStore.getChannelId();
                if (channelId) {
                    try {
                        const pendingReply = PendingReplyStore.getPendingReply(channelId);
                        const options = pendingReply
                            ? MessageActions.getSendMessageOptionsForReply(pendingReply)
                            : {};

                        const result = sendMessage(channelId, { content: url }, false, options);

                        Promise.resolve(result)
                            .then(() => {
                                FluxDispatcher.dispatch({ type: "DELETE_PENDING_REPLY", channelId });
                            })
                            .catch(() => insertTextIntoChatInputBox(url + " "));
                    } catch {
                        insertTextIntoChatInputBox(url + " ");
                    }
                } else {
                    insertTextIntoChatInputBox(url + " ");
                }

                // Shift — отправить несколько гифок подряд, не закрывая панель
                if (e.shiftKey) return;

                closeOverlay();
                closePopup();
                ExpressionPickerStore.closeExpressionPicker();
            });

            grid.appendChild(tile);
        }
        body.appendChild(grid);
    }

    overlay.append(head, body);
}

/* ---------------------------------------------------------------- */
/*  “Click GIFs to add” mode                                       */
/* ---------------------------------------------------------------- */

function startAddMode(catId: string) {
    addMode = catId;
    document.body.classList.add("sg-add-active");
    if (overlay) overlay.style.display = "none";
    if (banner) {
        const cat = categories.find(c => c.id === catId);
        const text = banner.querySelector(".sg-banner-text");
        if (text) {
            text.textContent = `Click GIFs to add them to “${cat?.name ?? "category"}”. Search and scrolling still work.`;
        }
        banner.classList.add("sg-show");
        banner.style.top = `${topOffset()}px`;
    }
    closePopup();
}

function endAddMode() {
    addMode = null;
    document.body.classList.remove("sg-add-active");
    banner?.classList.remove("sg-show");
    if (openCatId) {
        if (overlay) overlay.style.display = "flex";
        renderOverlay();
    }
}

function findTile(target: Element): Element | null {
    if (!drawer) return null;

    let node: Element | null = target;
    while (node && node !== drawer) {
        if (node instanceof HTMLElement && node.closest(".sg-ui")) return null;

        const rect = node.getBoundingClientRect();
        if (rect.width >= 48 && rect.height >= 48) {
            const media = node.querySelector("img, video");
            const bg = getComputedStyle(node).backgroundImage;
            if (media || (bg && bg !== "none")) return node;
        }
        node = node.parentElement;
    }
    return null;
}

/** Достаём полные данные гифки из React-пропсов — там есть ссылка на страницу гифки */
function gifFromFiber(element: Element): SavedGif | null {
    const key = Object.keys(element).find(k => k.startsWith("__reactFiber$"));
    if (!key) return null;

    let fiber: any = (element as any)[key];

    for (let i = 0; i < 18 && fiber; i++, fiber = fiber.return) {
        const props = fiber.memoizedProps;
        if (!props || typeof props !== "object") continue;

        const item = props.item;
        if (item && typeof item === "object"
            && typeof item.url === "string"
            && (typeof item.src === "string" || typeof item.gif_src === "string" || typeof item.gifSrc === "string")) {
            return {
                id: typeof item.id === "string" ? item.id : `g${Date.now().toString(36)}`,
                src: item.src || item.gif_src || item.gifSrc,
                gifSrc: item.gif_src || item.gifSrc,
                url: item.url,
                width: item.width || 0,
                height: item.height || 0
            };
        }

        // гифка-эмбед в чате: href — это ссылка на страницу гифки
        if (typeof props.href === "string" && typeof props.video?.url === "string") {
            return {
                id: `g${Date.now().toString(36)}`,
                src: props.video.url,
                url: props.href,
                width: props.width || 0,
                height: props.height || 0
            };
        }
    }

    return null;
}

function gifFromTile(tile: Element): SavedGif | null {
    const fromFiber = gifFromFiber(tile);
    if (fromFiber) return fromFiber;

    const img = tile.querySelector("img");
    let src = img?.currentSrc || img?.src || "";
    let width = img?.naturalWidth || 0;
    let height = img?.naturalHeight || 0;

    if (!src) {
        const bg = getComputedStyle(tile).backgroundImage;
        const m = /url\(["']?(.*?)["']?\)/.exec(bg);
        if (m) src = m[1];
    }

    const video = tile.querySelector("video");
    if (!src && video) src = video.currentSrc || video.src;

    if (!src) return null;

    let items: any[] = [];
    try {
        items = (GIFPickerViewStore as any)?.getResultItems?.() ?? [];
    } catch { }

    const found = items.find((i: any) =>
        [i.src, i.gifSrc, i.url].some(u => u && (
            normalize(u) === normalize(src)
            || normalize(decodeProxy(u)) === normalize(decodeProxy(src))
        ))
    );

    if (found) {
        return {
            id: found.id,
            src: found.src || found.gifSrc || src,
            gifSrc: found.gifSrc,
            url: decodeProxy(found.url || found.src || src),
            width: found.width || width || 0,
            height: found.height || height || 0
        };
    }

    const rect = tile.getBoundingClientRect();
    if (!width || !height) {
        width = Math.round(rect.width);
        height = Math.round(rect.height);
    }

    return { id: `g${Date.now().toString(36)}`, src, url: decodeProxy(src), width, height };
}

function swallow(e: Event) {
    if (!addMode) return;
    const t = e.target;
    if (!(t instanceof Element) || !drawer?.contains(t)) return;
    if (t.closest(".sg-ui")) return;
    e.preventDefault();
    e.stopPropagation();
    e.stopImmediatePropagation();
}

function onAddClick(e: MouseEvent) {
    if (!addMode) return;
    const t = e.target;
    if (!(t instanceof Element)) return;
    if (t.closest(".sg-ui")) return;
    if (!drawer?.contains(t)) return;

    const tile = findTile(t);
    if (!tile) return;
    // clicking a category tile is navigation, not adding a GIF
    if (tile.querySelector('[class*="categoryText_"]')) return;

    e.preventDefault();
    e.stopPropagation();
    e.stopImmediatePropagation();

    const gif = gifFromTile(tile);
    if (!gif) return;

    addGif(addMode, gif);
}

/* ---------------------------------------------------------------- */
/*  Plus button on GIFs in chat                                    */
/* ---------------------------------------------------------------- */

let chatMenu: HTMLDivElement | null = null;
let chatMenuGif: SavedGif | null = null;
let chatMenuNewInput = false;

function isGifUrl(url: string) {
    return /\.gif([?#]|$)/i.test(url) || /format=gif/i.test(url) || /animated=true/i.test(url);
}

function gifFromMessageBox(box: HTMLElement, preferredMedia?: HTMLElement | null): SavedGif | null {
    const fromFiber = gifFromFiber(box);
    if (fromFiber) return fromFiber;

    const media = (preferredMedia ?? box.querySelector("img, video")) as HTMLImageElement | HTMLVideoElement | null;
    if (!media) return null;

    let src = media.currentSrc || media.src || "";
    if (src.startsWith("blob:")) {
        const poster = media instanceof HTMLVideoElement ? media.poster : "";
        if (!poster) return null;
        src = poster;
    }
    if (!src) return null;

    const isVid = media instanceof HTMLVideoElement;
    const width = (isVid ? media.videoWidth : media.naturalWidth) || 0;
    const height = (isVid ? media.videoHeight : media.naturalHeight) || 0;

    return {
        id: `g${Date.now().toString(36)}`,
        src,
        url: decodeProxy(src),
        width,
        height
    };
}

function findGifBoxes() {
    const boxes = new Set<HTMLElement>();

    for (const element of document.querySelectorAll<HTMLElement>('[aria-label="GIF"]')) {
        if (element.closest('[class*="drawerSizingWrapper_"]') || element.closest(".sg-ui")) continue;
        if (element.parentElement?.closest('[aria-label="GIF"]')) continue;
        boxes.add(element);
    }

    const media = document.querySelectorAll<HTMLImageElement | HTMLVideoElement>(
        '[class*="messageContent"] img, [class*="messageContent"] video, [class*="embedWrapper"] img, [class*="embedWrapper"] video'
    );

    for (const element of media) {
        if (element.closest('[class*="drawerSizingWrapper_"]') || element.closest(".sg-ui")) continue;
        const src = element.currentSrc || element.src || "";
        if (!isGifUrl(src)) continue;

        const box = element.closest<HTMLElement>(
            '[class*="clickableWrapper"], [class*="imageWrapper"], [class*="embedWrapper"]'
        ) ?? element.parentElement;
        if (box) boxes.add(box);
    }

    // Надёжный признак: Discord сам показывает звёздочку только на гифках
    for (const star of document.querySelectorAll<HTMLElement>('[class*="gifFavoriteButton"]')) {
        if (star.closest('[class*="drawerSizingWrapper_"]') || star.closest(".sg-ui")) continue;

        const box = star.closest<HTMLElement>(
            '[class*="clickableWrapper"], [class*="imageWrapper"], [class*="embedWrapper"]'
        ) ?? star.parentElement?.parentElement;
        if (box) boxes.add(box);
    }

    // Обычные картинки в сообщениях (не только гифки)
    const images = document.querySelectorAll<HTMLImageElement>(
        '[role="article"] img, [class*="messageListItem"] img'
    );

    for (const img of images) {
        if (img.closest('[class*="drawerSizingWrapper_"]') || img.closest(".sg-ui")) continue;
        if (img.closest('[class*="emoji"]') || img.closest('[data-type="emoji"]')) continue;

        const src = img.currentSrc || img.src || "";
        if (!src || src.startsWith("data:") || src.startsWith("blob:")) continue;
        if (/\/emojis\/|\/avatars\/|\/icons\/|\/badges\//i.test(src)) continue;

        const rect = img.getBoundingClientRect();
        if (rect.width < 80 || rect.height < 80) continue;

        const box = img.closest<HTMLElement>(
            '[class*="imageWrapper"], [class*="mosaicItem"], [class*="clickableWrapper"], [class*="embedWrapper"], [class*="imageContent"]'
        ) ?? img.parentElement;
        if (box) boxes.add(box);
    }

    return boxes;
}

function injectGifButtons() {
    injectPickerPlusButtons();
}

/* ---------------------------------------------------------------- */
/*  Floating + button for media in chat                             */
/* ---------------------------------------------------------------- */

let floatingBtn: HTMLDivElement | null = null;
let hoverBox: HTMLElement | null = null;
let hoverMedia: HTMLElement | null = null;
let hoverRaf = false;

function ensureFloatingBtn() {
    if (floatingBtn) return floatingBtn;

    floatingBtn = el("div", "sg-msg-add sg-floating sg-ui", "+") as HTMLDivElement;
    floatingBtn.setAttribute("role", "button");
    floatingBtn.title = "Add to category";
    floatingBtn.style.display = "none";

    floatingBtn.addEventListener("pointerdown", e => {
        e.preventDefault();
        e.stopPropagation();
    });

    floatingBtn.addEventListener("click", e => {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();

        if (!hoverBox) return;

        const gif = gifFromMessageBox(hoverBox, hoverMedia);
        if (!gif) {
            showToast({ text: "Couldn't read this image", variant: "critical" });
            return;
        }

        openChatMenu(gif, floatingBtn!);
    });

    document.body.appendChild(floatingBtn);
    return floatingBtn;
}

function hideFloatingBtn() {
    hoverBox = null;
    hoverMedia = null;
    if (floatingBtn) floatingBtn.style.display = "none";
}

function showFloatingBtn(box: HTMLElement, media: HTMLElement) {
    const rect = media.getBoundingClientRect();

    if (rect.width < 80 || rect.height < 80) return;

    const btn = ensureFloatingBtn();
    hoverBox = box;
    hoverMedia = media;

    const left = Math.min(Math.max(8, rect.right - 38), window.innerWidth - 40);
    const top = Math.max(8, rect.top + 6);

    btn.style.display = "flex";
    btn.style.left = `${Math.round(left)}px`;
    btn.style.top = `${Math.round(top)}px`;
}

function findMediaBoxAt(x: number, y: number): { box: HTMLElement; media: HTMLElement; } | null {
    const element = document.elementFromPoint(x, y);
    if (!element) return null;
    if (element.closest(".sg-ui")) return null;
    if (element.closest('[class*="drawerSizingWrapper_"]')) return null;

    const direct = (element.closest("img, video") as HTMLElement | null)
        ?? (element.querySelector("img, video") as HTMLElement | null);

    let node: Element | null = element;
    for (let i = 0; i < 10 && node; i++, node = node.parentElement) {
        if (!node.matches('[aria-label="GIF"], [class*="imageWrapper"], [class*="clickableWrapper"], [class*="embedWrapper"], [class*="mosaicItem"]')) continue;

        const media = direct && node.contains(direct)
            ? direct
            : node.querySelector("img, video");

        if (!media) continue;

        const rect = media.getBoundingClientRect();
        if (rect.width < 80 || rect.height < 80) continue;
        if (!node.closest('[role="article"], [class*="messageListItem"]')) continue;

        return { box: node as HTMLElement, media: media as HTMLElement };
    }

    return null;
}

function onHoverMove(e: PointerEvent) {
    if (hoverRaf) return;

    hoverRaf = true;
    const x = e.clientX;
    const y = e.clientY;

    requestAnimationFrame(() => {
        hoverRaf = false;

        const target = document.elementFromPoint(x, y);
        if (target && target.closest(".sg-floating")) return;

        const found = findMediaBoxAt(x, y);
        if (found) showFloatingBtn(found.box, found.media);
        else hideFloatingBtn();
    });
}

/** Активна ли вкладка GIF в панели */
function isGifTabActive() {
    if (!drawer) return false;
    const active = drawer.querySelector<HTMLElement>('[class*="navButton"][aria-selected="true"]');
    if (!active) return false;
    return /gif/i.test(active.textContent || "");
}

/** Плюсики на гифках внутри панели GIF (Favorites, поиск и т.д.) */
function injectPickerPlusButtons() {
    if (!drawer) return;

    const tiles = drawer.querySelectorAll<HTMLElement>('[class*="result_"]');

    if (!isGifTabActive()) {
        for (const tile of tiles) tile.querySelector(":scope > .sg-msg-add")?.remove();
        return;
    }

    for (const tile of tiles) {
        if (tile.querySelector('[class*="categoryText_"]')) continue;
        if (!tile.querySelector("video, img")) continue;
        if (tile.querySelector(":scope > .sg-msg-add")) {
            tile.classList.add("sg-media-host");
            continue;
        }

        tile.classList.add("sg-media-host");

        const btn = el("div", "sg-msg-add sg-ui", "+");
        btn.setAttribute("role", "button");
        btn.title = "Add to category";

        btn.addEventListener("pointerdown", e => {
            e.preventDefault();
            e.stopPropagation();
        });

        btn.addEventListener("click", e => {
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();

            const gif = gifFromTile(tile);
            if (!gif) return;
            openChatMenu(gif, btn);
        });

        tile.appendChild(btn);
    }
}

function openChatMenu(gif: SavedGif, anchor: HTMLElement) {
    chatMenuGif = gif;
    chatMenuNewInput = false;

    if (!chatMenu) {
        chatMenu = el("div", "sg-popup sg-chat-menu sg-ui") as HTMLDivElement;

        // Клики внутри меню не должны считаться «кликом мимо» панели GIF
        for (const type of ["pointerdown", "mousedown", "click", "wheel"] as const) {
            chatMenu.addEventListener(type, e => e.stopPropagation());
        }
    }

    const host = drawer ?? document.body;
    if (chatMenu.parentElement !== host) host.appendChild(chatMenu);

    chatMenu.style.display = "block";
    renderChatMenu();

    const r = anchor.getBoundingClientRect();
    const menuRect = chatMenu.getBoundingClientRect();

    let left = r.right + 6;
    if (left + menuRect.width > window.innerWidth - 8) left = r.left - menuRect.width - 6;
    if (left < 8) left = 8;

    let top = r.top;
    if (top + menuRect.height > window.innerHeight - 8) top = window.innerHeight - menuRect.height - 8;
    if (top < 8) top = 8;

    chatMenu.style.left = `${Math.round(left)}px`;
    chatMenu.style.top = `${Math.round(top)}px`;
}

function closeChatMenu() {
    if (!chatMenu) return;
    chatMenu.style.display = "none";
    chatMenuGif = null;
    chatMenuNewInput = false;
}

function renderChatMenu() {
    if (!chatMenu) return;
    chatMenu.innerHTML = "";

    for (const cat of categories) {
        const row = el("div", "sg-row");
        row.append(
            el("span", "sg-row-name", cat.id === FAV_ID ? `★ ${cat.name}` : cat.name),
            el("span", "sg-count", String(cat.gifs.length))
        );

        row.addEventListener("click", () => {
            if (!chatMenuGif) return;
            addGif(cat.id, chatMenuGif);
            closeChatMenu();
        });

        chatMenu.appendChild(row);
    }

    chatMenu.appendChild(el("div", "sg-sep"));

    if (chatMenuNewInput) {
        const row = el("div", "sg-new");
        const input = el("input", "sg-input") as HTMLInputElement;
        input.placeholder = "Category name";
        input.maxLength = 40;

        const create = () => {
            const name = input.value.trim().slice(0, 40);
            if (!name || !chatMenuGif) return;

            const cat: SuperCategory = { id: `c${Date.now().toString(36)}`, name, gifs: [] };
            categories.push(cat);
            saveCategories();
            addGif(cat.id, chatMenuGif);
            renderPopup();
            renderCustomTiles(true);
            closeChatMenu();
        };

        input.addEventListener("keydown", e => {
            e.stopPropagation();
            if (e.key === "Enter") create();
            if (e.key === "Escape") { chatMenuNewInput = false; renderChatMenu(); }
        });

        const ok = el("button", "sg-btn", "Create") as HTMLButtonElement;
        ok.addEventListener("click", create);

        row.append(input, ok);
        chatMenu.appendChild(row);
        requestAnimationFrame(() => input.focus());
    } else {
        const add = el("div", "sg-row");
        add.append(el("span", "sg-row-name", "+ New Category"));
        add.addEventListener("click", () => { chatMenuNewInput = true; renderChatMenu(); });
        chatMenu.appendChild(add);
    }
}

/* ---------------------------------------------------------------- */
/*  Hiding standard categories                                     */
/* ---------------------------------------------------------------- */

const FAVORITES_NAME = /favorit|favoris|favori|favourite|favorite|избран|обране|preferit|ulubion|obl[ií]ben|любим|收藏|お気に入り|즐겨찾기|المفضل/i;

function isFavoritesLabel(label: HTMLElement) {
    const text = (label.textContent || "").trim();
    if (text && FAVORITES_NAME.test(text)) return true;

    // Favorites is the only tile with the blurple background
    const tile = label.closest<HTMLElement>('[class*="result_"]');
    return !!tile?.querySelector('[class*="categoryFadeBlurple_"]');
}

function shouldHideLabel(label: HTMLElement) {
    const text = (label.textContent || "").trim().toLowerCase();
    if (!text || text.length > 40) return false;

    if (settings.store.hideStandardCategories) return !isFavoritesLabel(label);

    const extra = settings.store.hideCategories
        .split(",")
        .map(s => s.trim().toLowerCase())
        .filter(Boolean);

    return extra.includes(text);
}

function refreshHiddenTiles() {
    if (!drawer) return;

    const labels = [...drawer.querySelectorAll<HTMLElement>('[class*="categoryText_"]')];

    // Keep Favorites. If we can't recognize it (other locale / Discord change),
    // keep the first tile so at least one standard category never disappears.
    const keep = settings.store.hideStandardCategories
        ? (labels.find(isFavoritesLabel) ?? labels[0] ?? null)
        : null;

    for (const node of drawer.querySelectorAll<HTMLElement>("[data-sg-hidden]")) {
        const label = node.querySelector<HTMLElement>('[class*="categoryText_"]');
        if (!label || label === keep || !shouldHideLabel(label)) {
            node.style.removeProperty("display");
            node.removeAttribute("data-sg-hidden");
        }
    }

    for (const label of labels) {
        if (label === keep) continue;
        if (!shouldHideLabel(label)) continue;

        const tile = label.closest<HTMLElement>('[class*="result_"]') ?? label.parentElement;
        if (!tile) continue;

        tile.dataset.sgHidden = "1";
        tile.style.setProperty("display", "none", "important");
    }

    renderCustomTiles();
    repackCategoryTiles();
    maskUnsettledGrid();
}

/**
 * Discord сначала рисует сетку в одну колонку и только потом пересчитывает.
 * Прячем сетку на этот момент, чтобы не мелькал неправильный первый кадр.
 */
function maskUnsettledGrid() {
    if (!drawer) return;
    if (performance.now() - drawerOpenedAt > 1500) return;

    const label = drawer.querySelector<HTMLElement>('[class*="categoryText_"]');
    const grid = label?.closest<HTMLElement>('[class*="result_"]')?.parentElement;
    if (!grid) return;

    const sample = grid.querySelector<HTMLElement>('[class*="result_"]');
    const sampleWidth = parseFloat(sample?.style.width ?? "")
        || sample?.getBoundingClientRect().width
        || 0;

    const widePanel = grid.clientWidth > 420;
    const unsettled = widePanel && sampleWidth > grid.clientWidth * 0.8;

    if (unsettled) {
        if (maskedGrid !== grid) {
            maskedGrid = grid;
            grid.style.visibility = "hidden";
        }

        if (maskTimer) clearTimeout(maskTimer);
        maskTimer = setTimeout(() => {
            grid.style.visibility = "";
            if (maskedGrid === grid) maskedGrid = null;
            maskTimer = null;
        }, 350);
        return;
    }

    if (maskedGrid === grid) {
        grid.style.visibility = "";
        maskedGrid = null;
    }

    if (maskTimer) {
        clearTimeout(maskTimer);
        maskTimer = null;
    }
}

/* ---------------------------------------------------------------- */
/*  Custom categories right in the grid                            */
/* ---------------------------------------------------------------- */

let lastGrid: HTMLElement | null = null;
let lastSig = "";

function categoriesSignature(width: number, height: number, gridWidth: number) {
    return categories
        .map(c => `${c.id}:${c.name}:${c.gifs.length}:${c.gifs[0]?.src ?? ""}`)
        .join("|")
        + `|${Math.round(width)}x${Math.round(height)}@${Math.round(gridWidth)}`;
}

/** Считаем раскладку сами от ширины сетки, чтобы не зависеть от промежуточных состояний Discord */
function computeGridMetrics(grid: HTMLElement) {
    const gridWidth = grid.clientWidth;
    if (gridWidth < 100) return null;

    const padding = 12;
    const gap = 12;
    const minTile = 200;

    const columns = Math.max(1, Math.floor(
        (gridWidth - padding * 2 + gap) / (minTile + gap)
    ));
    const width = Math.max(120,
        (gridWidth - padding * 2 - gap * (columns - 1)) / columns
    );

    const sample = grid.querySelector<HTMLElement>('[class*="result_"]');
    const height = parseFloat(sample?.style.height ?? "") || 110;

    return { columns, width, height, gap, left0: padding };
}

function renderCustomTiles(force = false) {
    if (!drawer) return;

    const label = drawer.querySelector<HTMLElement>('[class*="categoryText_"]');
    const grid = label?.closest<HTMLElement>('[class*="result_"]')?.parentElement ?? null;

    if (!grid) {
        for (const n of document.querySelectorAll(".sg-cat-tile")) n.remove();
        lastGrid = null;
        lastSig = "";
        return;
    }

    const metrics = computeGridMetrics(grid);
    if (!metrics) return;

    const { width, height } = metrics;
    const sig = categoriesSignature(width, height, grid.clientWidth);
    const fresh = !!grid.querySelector(".sg-cat-tile");
    if (!force && grid === lastGrid && sig === lastSig && fresh) return;

    lastGrid = grid;
    lastSig = sig;

    for (const n of document.querySelectorAll(".sg-cat-tile")) n.remove();

    for (const cat of categories) grid.appendChild(makeCategoryTile(cat, width, height));
    grid.appendChild(makeCreateTile(width, height));

    repackCategoryTiles();
}

function makeCategoryTile(cat: SuperCategory, width: number, height: number) {
    const tile = el("div", "sg-cat-tile sg-ui");
    tile.dataset.sgCat = cat.id;
    tile.setAttribute("role", "button");
    tile.tabIndex = 0;
    tile.style.width = `${width}px`;
    tile.style.height = `${height}px`;
    tile.title = cat.gifs.length
        ? `${cat.name} — ${cat.gifs.length} GIFs`
        : `${cat.name} — empty`;

    const preview = cat.gifs[0];
    if (preview) {
        const media = preview.gifSrc || preview.src || preview.url;
        if (media && isVideo(media)) {
            const video = document.createElement("video");
            video.className = "sg-cat-preview";
            video.src = media;
            video.muted = true;
            video.loop = true;
            video.autoplay = true;
            video.playsInline = true;
            tile.appendChild(video);
        } else if (media) {
            tile.style.backgroundImage = `url("${media}")`;
        }
    }

    tile.appendChild(el("span", "sg-cat-name", cat.name));
    if (cat.gifs.length) tile.appendChild(el("span", "sg-cat-count", String(cat.gifs.length)));

    const del = el("button", "sg-cat-del sg-ui", "✕") as HTMLButtonElement;
    del.type = "button";
    del.title = `Delete “${cat.name}”`;
    del.addEventListener("pointerdown", e => e.stopPropagation());
    del.addEventListener("click", e => {
        e.preventDefault();
        e.stopPropagation();
        confirmDeleteTile(tile, cat);
    });
    tile.appendChild(del);

    tile.addEventListener("click", e => {
        if (tile.querySelector(".sg-cat-input") || tile.classList.contains("sg-cat-confirm")) return;
        e.preventDefault();
        e.stopPropagation();

        if (addMode) {
            startAddMode(cat.id);
            return;
        }

        closePopup();
        openOverlay(cat.id);
    });

    tile.addEventListener("keydown", e => {
        if (tile.querySelector(".sg-cat-input") || tile.classList.contains("sg-cat-confirm")) return;
        if (e.key !== "Enter" && e.key !== " ") return;
        e.preventDefault();
        closePopup();
        openOverlay(cat.id);
    });

    tile.addEventListener("dblclick", e => {
        if (tile.querySelector(".sg-cat-input") || tile.classList.contains("sg-cat-confirm")) return;
        e.preventDefault();
        e.stopPropagation();
        startTileEdit(tile, cat.name, "Category name", value => {
            if (value.trim()) renameCategory(cat.id, value);
            else renderCustomTiles(true);
        });
    });

    return tile;
}

function confirmDeleteTile(tile: HTMLElement, cat: SuperCategory) {
    tile.classList.add("sg-cat-confirm");
    tile.innerHTML = "";

    tile.appendChild(el("span", "sg-cat-name", `Delete “${cat.name}”?`));

    const bar = el("div", "sg-cat-confirm-btns");
    const yes = el("button", "sg-btn", "Yes") as HTMLButtonElement;
    const no = el("button", "sg-btn sg-plain", "No") as HTMLButtonElement;
    yes.type = "button";
    no.type = "button";

    yes.addEventListener("click", e => {
        e.preventDefault();
        e.stopPropagation();
        deleteCategory(cat.id);
    });
    no.addEventListener("click", e => {
        e.preventDefault();
        e.stopPropagation();
        renderCustomTiles(true);
    });

    bar.append(yes, no);
    tile.appendChild(bar);
}

function makeCreateTile(width: number, height: number) {
    const tile = el("div", "sg-cat-tile sg-cat-plus sg-ui");
    tile.setAttribute("role", "button");
    tile.tabIndex = 0;
    tile.style.width = `${width}px`;
    tile.style.height = `${height}px`;
    tile.title = "Create category";
    tile.appendChild(el("span", "sg-cat-name", "+ New Category"));

    tile.addEventListener("click", e => {
        if (tile.querySelector(".sg-cat-input")) return;
        e.preventDefault();
        e.stopPropagation();
        startTileEdit(tile, "", "Category name", value => {
            if (value.trim()) createCategory(value);
            else renderCustomTiles(true);
        });
    });

    tile.addEventListener("keydown", e => {
        if (tile.querySelector(".sg-cat-input")) return;
        if (e.key !== "Enter" && e.key !== " ") return;
        e.preventDefault();
        startTileEdit(tile, "", "Category name", value => {
            if (value.trim()) createCategory(value);
            else renderCustomTiles(true);
        });
    });

    return tile;
}

function startTileEdit(tile: HTMLElement, initial: string, placeholder: string, commit: (value: string) => void) {
    tile.classList.remove("sg-cat-confirm");
    tile.innerHTML = "";

    const input = el("input", "sg-cat-input") as HTMLInputElement;
    input.value = initial;
    input.placeholder = placeholder;
    input.maxLength = 40;

    let finished = false;
    const done = (save: boolean) => {
        if (finished) return;
        finished = true;
        if (save) commit(input.value);
        else renderCustomTiles(true);
    };

    input.addEventListener("keydown", e => {
        e.stopPropagation();
        if (e.key === "Enter") done(true);
        if (e.key === "Escape") done(false);
    });
    input.addEventListener("blur", () => done(true));
    input.addEventListener("pointerdown", e => e.stopPropagation());
    input.addEventListener("click", e => e.stopPropagation());
    input.addEventListener("dblclick", e => e.stopPropagation());

    tile.appendChild(input);
    requestAnimationFrame(() => { input.focus(); input.select(); });
}

/** Re-lays out remaining categories (including custom ones) without gaps */
function repackCategoryTiles() {
    if (!drawer) return;

    const firstLabel = drawer.querySelector<HTMLElement>('[class*="categoryText_"]');
    const grid = firstLabel?.closest<HTMLElement>('[class*="result_"]')?.parentElement;
    if (!grid) return;

    const tiles = [...grid.children].filter((n): n is HTMLElement =>
        n instanceof HTMLElement
        && (
            (/result_/.test(n.className) && !!n.querySelector('[class*="categoryText_"]'))
            || n.classList.contains("sg-cat-tile")
        )
    );
    if (tiles.length < 2) return;

    const metrics = computeGridMetrics(grid);
    if (!metrics) return;

    const { columns, width, height, gap, left0 } = metrics;

    const visible = tiles.filter(t => !t.dataset.sgHidden);
    // custom categories first, then standard ones (order within groups is preserved)
    visible.sort((a, b) =>
        Number(b.classList.contains("sg-cat-tile")) - Number(a.classList.contains("sg-cat-tile"))
    );

    visible.forEach((tile, i) => {
        tile.style.width = `${width}px`;
        tile.style.height = `${height}px`;
        tile.style.left = `${left0 + (i % columns) * (width + gap)}px`;
        tile.style.top = `${Math.floor(i / columns) * (height + gap)}px`;
    });

    const rows = Math.ceil(visible.length / columns);
    const totalHeight = rows * height + Math.max(0, rows - 1) * gap;

    grid.style.height = `${totalHeight}px`;
    const content = grid.parentElement;
    if (content && /content_/.test(content.className)) {
        content.style.height = `${totalHeight + left0}px`;
    }
}

/* ---------------------------------------------------------------- */
/*  Mounting                                                       */
/* ---------------------------------------------------------------- */

function unmount() {
    resizeObserver?.disconnect();
    resizeObserver = null;

    drawerObserver?.disconnect();
    drawerObserver = null;

    if (maskTimer) {
        clearTimeout(maskTimer);
        maskTimer = null;
    }
    if (maskedGrid) {
        maskedGrid.style.visibility = "";
        maskedGrid = null;
    }
    drawerOpenedAt = 0;

    const input = findSearchInput();
    input?.removeEventListener("keydown", onSearchKeyDown);
    input?.removeEventListener("input", placeStar);
    input?.style.removeProperty("padding-right");

    star?.remove();
    popup?.remove();
    overlay?.remove();
    banner?.remove();
    star = popup = overlay = banner = null;

    drawer?.style.removeProperty("max-height");
    drawer = null;

    addMode = null;
    openCatId = null;
    document.body.classList.remove("sg-add-active");
}

function mount() {
    const found = findDrawer();

    // Панель закрыта — сбрасываем состояние, иначе меню будет открываться в отсоединённой панели
    if (!found) {
        if (drawer) unmount();
        return;
    }

    const input0 = findSearchInput(found);
    if (!input0) return;

    if (found === drawer && star?.isConnected && popup?.isConnected && overlay?.isConnected && banner?.isConnected) {
        updatePosition();
        return;
    }

    unmount();
    drawer = found;
    drawerOpenedAt = performance.now();

    resizeObserver?.disconnect();
    try {
        resizeObserver = new ResizeObserver(() => scheduleHiddenTiles());
        resizeObserver.observe(drawer);
    } catch { }

    drawerObserver?.disconnect();
    try {
        drawerObserver = new MutationObserver(() => scheduleHiddenTiles());
        drawerObserver.observe(drawer, { attributes: true, attributeFilter: ["style"], subtree: true });
    } catch { }

    const input = findSearchInput()!;
    const parent = input.parentElement!;
    if (getComputedStyle(parent).position === "static") parent.style.position = "relative";
    input.style.paddingRight = "36px";

    star = el("button", "sg-star sg-ui") as HTMLButtonElement;
    star.type = "button";
    star.title = "Super GIFs and my categories";
    star.innerHTML = '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2.6l2.9 5.9 6.5.9-4.7 4.6 1.1 6.5-5.8-3.1-5.8 3.1 1.1-6.5L2.6 9.4l6.5-.9L12 2.6z"/></svg>';
    star.addEventListener("click", e => {
        e.preventDefault();
        e.stopPropagation();
        if (popup?.style.display === "block") closePopup();
        else openPopup();
    });
    parent.appendChild(star);

    popup = el("div", "sg-popup sg-ui") as HTMLDivElement;
    popup.style.display = "none";
    drawer.appendChild(popup);

    overlay = el("div", "sg-overlay sg-ui") as HTMLDivElement;
    overlay.style.display = "none";
    drawer.appendChild(overlay);

    banner = el("div", "sg-banner sg-ui") as HTMLDivElement;
    const bText = el("span", "sg-banner-text");
    const bDone = el("button", "sg-btn", "Done") as HTMLButtonElement;
    bDone.type = "button";
    bDone.addEventListener("click", () => endAddMode());
    banner.append(bText, bDone);
    drawer.appendChild(banner);

    updatePosition();

    input.addEventListener("keydown", onSearchKeyDown);
    input.addEventListener("input", placeStar);
    window.addEventListener("resize", updatePosition);

    placeStar();

    refreshHiddenTiles();
}

function onSearchKeyDown(e: KeyboardEvent) {
    if (e.key === "Escape") {
        closePopup();
        closeOverlay();
    }
}

let hideTimer: ReturnType<typeof setTimeout> | null = null;
let processing = false;

function scheduleHiddenTiles() {
    if (hideTimer) return;
    hideTimer = setTimeout(() => {
        hideTimer = null;
        processNow();
    }, 120);
}

/** Synchronous processing: runs before the frame is painted, so there is no flicker */
function processNow() {
    if (!drawer || processing) return;

    processing = true;
    try {
        refreshHiddenTiles();
    } catch { }
    try {
        injectGifButtons();
    } catch { }
    try {
        clampDrawerHeight();
    } catch { }
    processing = false;
}

function onDocumentPointerDown(e: PointerEvent) {
    const t = e.target;
    if (!(t instanceof Element)) return;

    if (chatMenu && chatMenu.style.display === "block") {
        const rect = chatMenu.getBoundingClientRect();
        const insideMenu = chatMenu.contains(t)
            || (e.clientX >= rect.left && e.clientX <= rect.right
                && e.clientY >= rect.top && e.clientY <= rect.bottom);

        if (!insideMenu && !t.closest(".sg-msg-add")) closeChatMenu();
    }

    if (!popup || popup.style.display !== "block") return;
    if (popup.contains(t) || star?.contains(t)) return;
    closePopup();
}

function onWindowScroll(e: Event) {
    const target = e.target;
    if (target instanceof Node && chatMenu?.contains(target)) return;
    closeChatMenu();
}

export default definePlugin({
    name: "SuperGifs",
    description: "Super Favorites and custom GIF categories right inside the GIF picker",
    authors: [{ name: "local", id: 0n }],
    tags: ["Emotes", "Media", "Customisation"],
    enabledByDefault: true,
    settings,

    async start() {
        const style = document.createElement("style");
        style.id = STYLE_ID;
        style.textContent = CSS;
        document.head.appendChild(style);

        try {
            await loadCategories();
        } catch { }

        document.addEventListener("pointerdown", onDocumentPointerDown, true);
        document.addEventListener("pointerdown", swallow, true);
        document.addEventListener("pointerup", swallow, true);
        document.addEventListener("click", onAddClick, true);
        document.addEventListener("pointermove", onHoverMove, { passive: true });
        window.addEventListener("scroll", hideFloatingBtn, true);
        window.addEventListener("blur", hideFloatingBtn);
        window.addEventListener("scroll", onWindowScroll, true);

        observer = new MutationObserver(mutations => {
            try {
                mount();
            } catch { }

            const currentDrawer = drawer;
            const relevant = !!currentDrawer && mutations.some(m => {
                const target = m.target;
                return target instanceof Node && (target === currentDrawer || currentDrawer.contains(target));
            });

            if (relevant) processNow();
            else scheduleHiddenTiles();
        });
        observer.observe(document.body, { childList: true, subtree: true });

        mount();
        injectGifButtons();

        ensureTimer = setInterval(() => {
            try {
                injectGifButtons();
            } catch { }
            try {
                clampDrawerHeight();
            } catch { }
        }, 1000);
    },

    stop() {
        observer?.disconnect();
        observer = null;

        if (hideTimer) {
            clearTimeout(hideTimer);
            hideTimer = null;
        }

        if (ensureTimer) {
            clearInterval(ensureTimer);
            ensureTimer = null;
        }

        document.removeEventListener("pointerdown", onDocumentPointerDown, true);
        document.removeEventListener("pointerdown", swallow, true);
        document.removeEventListener("pointerup", swallow, true);
        document.removeEventListener("click", onAddClick, true);
        document.removeEventListener("pointermove", onHoverMove);
        window.removeEventListener("scroll", hideFloatingBtn, true);
        window.removeEventListener("blur", hideFloatingBtn);
        window.removeEventListener("resize", updatePosition);
        window.removeEventListener("scroll", onWindowScroll, true);

        document.body.classList.remove("sg-add-active");

        for (const btn of document.querySelectorAll(".sg-msg-add")) btn.remove();
        floatingBtn?.remove();
        floatingBtn = null;
        hoverBox = null;
        chatMenu?.remove();
        chatMenu = null;
        chatMenuGif = null;

        unmount();
        addMode = null;
        openCatId = null;
        document.getElementById(STYLE_ID)?.remove();
    }
});
'@

Write-Host ""
Write-Host "  ==========================================" -ForegroundColor Magenta
Write-Host "   BigPicker for Discord — setup" -ForegroundColor Magenta
Write-Host "  ==========================================" -ForegroundColor Magenta

Say "Checking Node.js"
Ensure-Tool "OpenJS.NodeJS.LTS" "Node.js" "node" "https://nodejs.org/ (LTS version)"
if (-not (Test-NodeOk)) { Fail "Node.js 22 or newer is required. Install the LTS build from https://nodejs.org/ and run the installer again." }
Ok "Node.js: $(& node -v)"

Say "Checking Git"
Ensure-Tool "Git.Git" "Git" "git" "https://git-scm.com/download/win"
Ok "Git: $(& git --version)"

Say "Downloading Vencord into $InstallDir"
if (Test-Path (Join-Path $InstallDir "package.json")) {
    Push-Location $InstallDir
    try {
        $code = Run "git" @("pull", "--ff-only")
        if ($code -eq 0) { Ok "Vencord updated" } else { Warn "Update failed, using the existing copy" }
    } finally { Pop-Location }
} else {
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
    New-Item -ItemType Directory -Force (Split-Path $InstallDir) | Out-Null
    $code = Run "git" @("clone", "--depth", "1", "https://github.com/Vendicated/Vencord", $InstallDir)
    if ($code -ne 0) { Fail "Could not download Vencord. Check your internet connection and run the installer again." }
    Ok "Vencord downloaded"
}

Say "Adding the BigPicker plugin"
$pluginDir = Join-Path $InstallDir "src\userplugins\bigPicker"
New-Item -ItemType Directory -Force $pluginDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $pluginDir "index.ts"), $pluginSource, (New-Object System.Text.UTF8Encoding($false)))
Ok "Plugin installed"

Say "Adding the SuperGifs plugin"
$superGifsDir = Join-Path $InstallDir "src\userplugins\superGifs"
New-Item -ItemType Directory -Force $superGifsDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $superGifsDir "index.ts"), $superGifsPluginSource, (New-Object System.Text.UTF8Encoding($false)))
Ok "SuperGifs installed"

$env:COREPACK_ENABLE_DOWNLOAD_PROMPT = "0"
$pnpm = Resolve-Pnpm
Push-Location $InstallDir
try {
    Say "Installing dependencies (1-2 minutes)"
    $code = Run $pnpm.Exe ($pnpm.Args + @("install", "--frozen-lockfile"))
    if ($code -ne 0) { Fail "pnpm install failed." }

    Say "Building Vencord"
    $code = Run $pnpm.Exe ($pnpm.Args + @("build"))
    if ($code -ne 0) { Fail "The build failed." }
    Ok "Built"
} finally { Pop-Location }

if ($SkipDiscordPatch) {
    Warn "Skipping the Discord patch (-SkipDiscordPatch)"
} else {
    Say "Closing Discord"
    Get-Process Discord -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3

    $installer = Join-Path $env:TEMP "VencordInstallerCli.exe"
    if (-not (Test-Path $installer)) {
        Say "Downloading the Vencord installer"
        Invoke-WebRequest -Uri "https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe" -OutFile $installer -UseBasicParsing
    }

    Say "Patching Discord (takes one second)"
    $env:VENCORD_USER_DATA_DIR = $InstallDir
    $env:VENCORD_DEV_INSTALL = "1"
    $code = Run $installer @("-install", "-branch", "auto")
    if ($code -ne 0) { Fail "The Vencord installer failed." }

    Say "Starting Discord"
    $updater = Join-Path $env:LOCALAPPDATA "Discord\Update.exe"
    if (Test-Path $updater) {
        Start-Process $updater -ArgumentList "--processStart", "Discord.exe"
    } else {
        Warn "Discord was not found in the default location — start it manually."
    }
}

Write-Host ""
Write-Host "  Done!" -ForegroundColor Green
Write-Host ""
Write-Host "  How to use:" -ForegroundColor White
Write-Host "   - open the GIF picker in any chat"
Write-Host "   - drag the small diagonal handle in the top-left corner to resize the panel"
Write-Host "   - double-click the handle to reset the size"
Write-Host "   - the star on the right side of the search bar opens Super GIFs and your categories"
Write-Host "   - exact sizes: Discord Settings -> Vencord -> Plugins -> BigPicker"
Write-Host ""
Write-Host "  Important: do not delete or move the folder $InstallDir." -ForegroundColor Yellow
Write-Host "  If the panel disappears after a Discord update, run this file again." -ForegroundColor Yellow
Write-Host ""
if (-not $NoPause) { Read-Host "Press Enter to close" }
