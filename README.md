# CodeFace — living ASCII smiley wallpaper (Lively / Windows)

A field of code characters with a face hidden in the empty space. It watches your
cursor, reacts to your typing with creepy replies built from your own files, pulls
rare strange expressions, and dodges out from under your windows.

## Setup
1. **Lively Wallpaper** (free, Microsoft Store) → **Add Wallpaper** → pick
   `smiley-wallpaper.html` from this folder.
2. In Lively, turn **Mouse input ON** (so the eyes follow the cursor).
3. Double-click **`StartForLively.cmd`** to start the helper (the "brain").
   - Optional: **`InstallLivelyAutostart.cmd`** makes it start at login.

Without the helper the face still works — it just loses the file-aware replies,
window-dodging, and click reactions.

## Using it
- **Type anywhere** → your letters appear near the face, then a creepy reply follows.
- **Move the mouse** → the eyes slowly track it.
- **Cover the screen with windows** → the face slides to an empty spot and frowns.
- Occasional rare faces: a manic grin, a toothy grin, and a very rare sad/tear moment.

## Privacy
The helper reads file names and text in your **Documents** and **Downloads** to make
its replies. **Everything stays on this PC** (localhost only, no internet). Its files
(`codeface-memory.json`, logs) stay in this folder. To change what it reads, edit
`$ScanDirs` at the top of `helper\creepy-helper.ps1`, then restart the helper.

## Stop / remove
- **`Stop.cmd`** — stop the helper.
- **`RemoveLivelyAutostart.cmd`** — undo auto-start.
- Remove the wallpaper in Lively.

*Windows-only (uses Lively + Windows PowerShell). The visual runs in any browser, but
the smart features would need a separate helper on macOS/Linux.*
