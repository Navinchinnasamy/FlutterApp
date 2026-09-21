# Pantry

Local-first grocery stock tracking for a household.

## Run the web app

Requires Node.js 22.5 or newer because the app uses Node's built-in SQLite support.

```bash
npm start
```

Then open `http://localhost:3000` on the laptop. The database is stored at `pantry.sqlite` beside the app.

## Use from another device on home Wi-Fi

1. Start the server on the laptop with `npm start`.
2. Find the laptop's local IP address.
3. On a device connected to the same Wi-Fi, open `http://LAPTOP_IP:3000`.

The server binds to the local network, keeps data in SQLite, and provides:

- `GET /api/health` for connection checks
- `GET /api/state` to read the current household data
- `PUT /api/state` to save the current web-app state
- `PUT /api/sync` to merge timestamped changes from a device
- `GET /api/backup` to export a JSON backup of the household data
- `PUT /api/restore` to restore a validated JSON backup

The API is intentionally local-network oriented. It is not intended to be exposed directly to the public internet.
