# Vencord Web with BigPicker & SuperGifs (browser)

Prebuilt Vencord Web extension (Chromium + Firefox) and userscript with the
**BigPicker** and **SuperGifs** plugins included.

These builds include all Vencord plugins; BigPicker and SuperGifs are enabled by default.

## Chrome / Edge

1. Unzip `extension-chrome.zip`.
2. Open `chrome://extensions` (or `edge://extensions`).
3. Enable **Developer mode**.
4. Click **Load unpacked** and select the unzipped folder (the one with `manifest.json`).
5. Open https://discord.com/app and reload the tab.

## Firefox

1. Unzip `extension-firefox.zip`.
2. Open `about:debugging#/runtime/this-firefox`.
3. Click **Load Temporary Add-on** and select `manifest.json` from the unzipped folder.
   This is temporary and disappears after a browser restart. A permanent install requires a signed add-on.
4. Open https://discord.com/app and reload the tab.

## Userscript

Install Tampermonkey or Violentmonkey, add `Vencord.user.js`, then open https://discord.com/app.

## Notes

- Categories are stored in the browser (IndexedDB for `discord.com`). They do **not** sync with the
  desktop app or with other browsers.
- The desktop `Install.bat` is not used for the browser build.
- The extension is unsigned: Chrome/Edge will show a warning when loading it unpacked. That is expected.
- Discord's browser client uses the same UI, so the panel, categories, hover buttons and instant send
  work the same way. Minor differences are possible after Discord updates.
- To rebuild after plugin changes: in `%LOCALAPPDATA%\Vencord` run `corepack pnpm buildWeb`, then copy:
  - `dist/extension-chrome.zip`
  - `dist/extension-firefox.zip`
  - `dist/Vencord.user.js`
