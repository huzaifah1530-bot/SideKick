# Remote configuration

SideKick reads these files from the repository's default branch at runtime. Changes reach users without a new app release.

## anisette-servers.json

Used by Settings → Advanced → Anisette → **Use Newest Anisette Server**. When the recommended server is patched or goes offline, add a replacement entry and point `recommended` at its `id`.

- `schemaVersion`: must be `1`.
- `updatedAt`: ISO 8601 date. SideKick shows the file's last commit date and falls back to this value.
- `recommended`: `id` of the server SideKick applies.
- `servers[].url`: must be HTTPS.
- `servers[].headers`: `X-Mme-Client-Info` and `User-Agent` are required. These are the only headers SideKick can send today. SideKick rejects any other header rather than dropping it.

Never put device identifiers, serial numbers or account data here. Every user receives the same values.
