// The last step of `npm run derle` (DD-258): writes ../../console/yeni/kaynak.sha256, the digest of the
// sources this build came from. For every regular file under this folder except node_modules/, in byte
// order of its relative path, the line "<sha256 of the file>  <path>\n"; the digest is the sha256 of
// those lines. kaynak-ozeti.sh computes the same value with POSIX tools, so a test can tell whether the
// committed build matches the committed sources without Node.
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const root = fileURLToPath(new URL(".", import.meta.url));
const NAME = /^[A-Za-z0-9._@+\/-]+$/;
const sha256 = (data) => createHash("sha256").update(data).digest("hex");

const files = [];
const walk = (dir, prefix) => {
  for (const entry of readdirSync(join(root, dir), { withFileTypes: true })) {
    const rel = prefix + entry.name;
    if (rel === "node_modules") continue;
    if (entry.isDirectory()) walk(rel, rel + "/");
    else if (entry.isFile()) {
      if (!NAME.test(rel)) throw new Error(`${rel}: kaynak dosya adında yalnız harf, rakam ve . _ @ + - / kullanılır`);
      files.push(rel);
    }
  }
};
walk(".", "");
files.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));

const lines = files.map((rel) => `${sha256(readFileSync(join(root, rel)))}  ${rel}\n`).join("");
const digest = sha256(Buffer.from(lines, "utf8"));
const out = new URL("../../console/yeni/kaynak.sha256", import.meta.url);
writeFileSync(out, digest + "\n");
console.log(`${fileURLToPath(out)}: ${digest} (${files.length} kaynak dosya)`);
