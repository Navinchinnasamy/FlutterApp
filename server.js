const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const {DatabaseSync} = require("node:sqlite");
const {Bonjour} = require("bonjour-service");

const root = __dirname;
const port = Number(process.env.PORT || 3000);
const host = process.env.HOST || "0.0.0.0";
const database = new DatabaseSync(path.join(root, "pantry.sqlite"));
database.exec(`
  CREATE TABLE IF NOT EXISTS items (
    id INTEGER PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    quantity TEXT NOT NULL,
    date TEXT NOT NULL,
    icon TEXT NOT NULL,
    status TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS shopping (
    id INTEGER PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    name TEXT NOT NULL,
    note TEXT NOT NULL,
    icon TEXT NOT NULL,
    done INTEGER NOT NULL DEFAULT 0,
    who TEXT NOT NULL
  );
`);
try { database.exec("ALTER TABLE shopping ADD COLUMN category TEXT NOT NULL DEFAULT 'Pantry'"); } catch (error) { if (!error.message.includes("duplicate column name")) throw error; }
try { database.exec("ALTER TABLE shopping ADD COLUMN date TEXT NOT NULL DEFAULT '2026-09-30'"); } catch (error) { if (!error.message.includes("duplicate column name")) throw error; }
try { database.exec("ALTER TABLE items ADD COLUMN shopping_id INTEGER"); } catch (error) { if (!error.message.includes("duplicate column name")) throw error; }
try { database.exec("ALTER TABLE items ADD COLUMN created_at TEXT"); } catch (error) { if (!error.message.includes("duplicate column name")) throw error; }
try { database.exec("ALTER TABLE items ADD COLUMN updated_at TEXT"); } catch (error) { if (!error.message.includes("duplicate column name")) throw error; }
try { database.exec("ALTER TABLE shopping ADD COLUMN created_at TEXT"); } catch (error) { if (!error.message.includes("duplicate column name")) throw error; }
try { database.exec("ALTER TABLE shopping ADD COLUMN updated_at TEXT"); } catch (error) { if (!error.message.includes("duplicate column name")) throw error; }
try { database.exec("ALTER TABLE items ADD COLUMN deleted_at TEXT"); } catch (error) { if (!error.message.includes("duplicate column name")) throw error; }
try { database.exec("ALTER TABLE shopping ADD COLUMN deleted_at TEXT"); } catch (error) { if (!error.message.includes("duplicate column name")) throw error; }
database.exec("UPDATE items SET created_at = COALESCE(created_at, datetime('now')), updated_at = COALESCE(updated_at, datetime('now')); UPDATE shopping SET created_at = COALESCE(created_at, datetime('now')), updated_at = COALESCE(updated_at, datetime('now'));");

function state() {
  return {
    items: database.prepare("SELECT id, shopping_id AS shoppingId, created_at AS createdAt, updated_at AS updatedAt, deleted_at AS deletedAt, name, category, quantity, date, icon, status FROM items ORDER BY id DESC").all(),
    shopping: database.prepare("SELECT id, created_at AS createdAt, updated_at AS updatedAt, deleted_at AS deletedAt, name, note, category, date, icon, done, who FROM shopping ORDER BY id DESC").all().map(item => ({...item, done: Boolean(item.done)}))
  };
}

function replaceState(next) {
  if (!Array.isArray(next.items) || !Array.isArray(next.shopping)) throw new Error("Invalid state");
  database.exec("BEGIN");
  try {
    database.exec("DELETE FROM items; DELETE FROM shopping;");
    const insertItem = database.prepare("INSERT INTO items (id, shopping_id, created_at, updated_at, deleted_at, name, category, quantity, date, icon, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
    for (const item of next.items) {
      const createdAt = item.createdAt || new Date().toISOString();
      insertItem.run(item.id, item.shoppingId || null, createdAt, item.updatedAt || createdAt, item.deletedAt || null, item.name, item.category, item.quantity, item.date, item.icon, item.status);
    }
    const insertShopping = database.prepare("INSERT INTO shopping (id, created_at, updated_at, deleted_at, name, note, category, date, icon, done, who) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
    for (const item of next.shopping) {
      const createdAt = item.createdAt || new Date().toISOString();
      insertShopping.run(item.id, createdAt, item.updatedAt || createdAt, item.deletedAt || null, item.name, item.note, item.category || "Pantry", item.date || "2026-09-30", item.icon, item.done ? 1 : 0, item.who);
    }
    database.exec("COMMIT");
  } catch (error) {
    database.exec("ROLLBACK");
    throw error;
  }
}

function newerRecord(localRecord, remoteRecord) {
  const localTime = Date.parse(localRecord?.updatedAt || localRecord?.updated_at || "") || 0;
  const remoteTime = Date.parse(remoteRecord?.updatedAt || remoteRecord?.updated_at || "") || 0;
  return remoteTime >= localTime ? remoteRecord : localRecord;
}

function mergeState(incoming) {
  if (!Array.isArray(incoming.items) || !Array.isArray(incoming.shopping)) throw new Error("Invalid state");
  const current = state();
  const mergeCollection = (local, remote) => {
    const merged = new Map(local.map(item => [String(item.id), item]));
    for (const item of remote) {
      const key = String(item.id);
      merged.set(key, merged.has(key) ? newerRecord(merged.get(key), item) : item);
    }
    return [...merged.values()];
  };
  const merged = {
    items: mergeCollection(current.items, incoming.items),
    shopping: mergeCollection(current.shopping, incoming.shopping)
  };
  replaceState(merged);
  return state();
}

function send(response, status, body, contentType = "application/json") {
  response.writeHead(status, {
    "Content-Type": `${contentType}; charset=utf-8`,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, PUT, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Cache-Control": contentType === "application/json" ? "no-store" : "public, max-age=300"
  });
  response.end(contentType === "application/json" ? JSON.stringify(body) : body);
}

function serveFile(request, response) {
  const requested = new URL(request.url, `http://${request.headers.host || "localhost"}`).pathname;
  const filePath = requested === "/" ? "/index.html" : requested;
  const file = path.resolve(root, `.${decodeURIComponent(filePath)}`);
  if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) return send(response, 404, {error: "Not found"});
  const types = {".html": "text/html", ".js": "text/javascript", ".css": "text/css"};
  send(response, 200, fs.readFileSync(file), types[path.extname(file)] || "application/octet-stream");
}

const server = http.createServer((request, response) => {
  const pathname = new URL(request.url, `http://${request.headers.host || "localhost"}`).pathname;
  if (request.method === "OPTIONS") return send(response, 204, "");
  if (pathname === "/api/health" && request.method === "GET") return send(response, 200, {ok: true, service: "pantry", database: "sqlite"});
  if (pathname === "/api/state" && request.method === "GET") return send(response, 200, state());
  if (pathname === "/api/state" && request.method === "PUT") {
    let body = "";
    request.on("data", chunk => {
      body += chunk;
      if (body.length > 1_000_000) request.destroy();
    });
    request.on("end", () => {
      try { replaceState(JSON.parse(body)); send(response, 200, state()); }
      catch (error) { send(response, 400, {error: error.message}); }
    });
    return;
  }
  if (pathname === "/api/sync" && request.method === "PUT") {
    let body = "";
    request.on("data", chunk => {
      body += chunk;
      if (body.length > 1_000_000) request.destroy();
    });
    request.on("end", () => {
      try { send(response, 200, mergeState(JSON.parse(body))); }
      catch (error) { send(response, 400, {error: error.message}); }
    });
    return;
  }
  if (request.method === "GET") return serveFile(request, response);
  send(response, 404, {error: "Not found"});
});

server.listen(port, host, () => {
  const bonjour = new Bonjour();
  bonjour.publish({name: "Pantry", type: "pantry", protocol: "tcp", port});
  console.log(`Pantry running at http://localhost:${port}`);
  console.log(`Home network access: http://<this-laptop-ip>:${port}`);
  console.log(`SQLite database: ${path.join(root, "pantry.sqlite")}`);
});
