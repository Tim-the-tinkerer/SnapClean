# Changelog

## 1.2.0 — 2026-07-25

- Session authorization: password dialog once per app launch (password never stored)
- “Forget Auth” control and menu item to clear session rights
- Privileged deletes via Security framework `AuthorizationRef` instead of AppleScript each time

## 1.1.0 — 2026-07-25

- Measure free space before and after each delete
- Report reclaimed space in the success status (e.g. “Deleted 2 snapshots · Freed 1.2 GB”)
- Session total: “Freed this session” in the header
- Explain when free space is unchanged (shared APFS blocks)

## 1.0.0 — 2026-07-25

- Initial release
- List local Time Machine snapshots (`tmutil listlocalsnapshotdates`)
- Multi-select delete and delete-all with confirmation
- Administrator elevation for `tmutil deletelocalsnapshots`
- Volume free-space summary for Macintosh HD — Data
