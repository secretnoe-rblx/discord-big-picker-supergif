 # 100% VIBECODED!!!
 # Big GIF & Emoji Panel for Discord + Super GIFs

Makes the standard GIF / emoji / sticker panel large and resizable, and adds
**Super GIFs** — your own favorites and custom GIF categories.

---

## Requirements

- Windows 10 or 11
- The **regular Discord desktop app** (not the browser)
- Internet connection
- About 5 minutes

Nothing else needs to be installed manually — Node.js and Git are installed automatically.

---

## Installation (2 steps)

**1.** Extract the `DiscordBigPicker` folder anywhere (for example, to your Desktop).

**2.** Double-click **`Install.bat`**.

The script will:

- install Node.js and Git if they are missing (a UAC prompt may appear — click **Yes**);
- download and build Vencord;
- add the BigPicker and SuperGifs plugins;
- close Discord, patch it and start it again.

It takes about **3–5 minutes**. When you see **“Done!”**, you're all set.

> If Windows shows the blue “Windows protected your PC” window —
> click **More info** → **Run anyway**.

## Updating

- **Desktop:** run `git pull` in this folder, then run `Install.bat` again. If the folder is a git clone, the installer also tries `git pull --ff-only` automatically.
- **Browser:** run `git pull`, then reinstall the extension from the updated `browser` folder (or rebuild it with `browser/build-browser.ps1`).

---

## How to use

### Panel

- Open the GIF panel (or the emoji panel) in any chat.
- Drag the small diagonal handle in the **top-left corner** to resize the panel.
- **Double-click** the handle to reset the size.
- While resizing, emojis and stickers re-flow **live** and fill the full width
  (the number of columns increases). Discord updates the grid about every 0.3 seconds.
- The panel **stays open** after you pick an emoji, so you can pick several in a row
  without losing your search. The same works in the reaction menu under a message.
- Exact sizes: Discord Settings → **Vencord** → **Plugins** → **BigPicker**.
- There is also a “keep the panel open” toggle there if you want the old behavior back.

### Super GIFs

- Your own categories appear as **tiles right in the GIF grid**, next to Favorites.
  Standard categories (hello, lol, love … kiss, Trending GIFs) are hidden.
- To create a category, use the **“+ New Category”** tile in the same grid.
- **Double-click** a category to rename it. Click the **✕** in its top-left corner to
  delete it (with a Yes/No confirmation).
- Click a category to open it; the **back arrow** returns to the grid.
- To save a GIF or image, click the **+** button:
  - on any GIF in the picker (for example in Favorites or in search results);
  - on any GIF or image in chat, even one sent by someone else.
  Then choose a category, or create a new one right there.
- **Clicking a saved GIF sends it to chat immediately.** Hold **Shift** while clicking to send several in a row without closing the panel.
- Discord's own favorite star sits on the left and our **+** on the right, so they never overlap.
- Show/hide standard categories: Settings → **Vencord** → **Plugins** → **SuperGifs**.

## Browser (Vencord Web)

Prebuilt browser builds are in the `browser` folder:

- `browser/extension-chrome.zip` — Chrome / Edge / Opera
- `browser/extension-firefox.zip` — Firefox
- `browser/Vencord.user.js` — Tampermonkey / Violentmonkey

Installation and caveats: see `browser/README.md`.

---

## Troubleshooting

**The panel disappeared after a Discord update**
→ Just run `Install.bat` again (it takes less than a minute).

**“Press Enter to close” and red error text**
→ Check your internet connection and run it again. If it still fails, send the error text.

**The .bat file opens in Notepad instead of running**
→ Right-click `Install.bat` → **Run as administrator**.

---

## Important

- Do **not** delete or move the folder `C:\Users\YOUR_NAME\AppData\Local\Vencord` — Discord loads the mod from it.
- Keep the `plugins` folder next to `Install.bat` — the installer takes the plugin sources from it.
  If you deleted it, just run `Install.bat` again.
- This is an unofficial mod. Discord often doesn't ban for it, but use it at your own risk.

---

## Uninstall

1. Discord Settings → **Vencord** → click **Uninstall** at the top (or run `VencordInstaller.exe` and click Uninstall).
2. You can delete the `C:\Users\YOUR_NAME\AppData\Local\Vencord` folder.
