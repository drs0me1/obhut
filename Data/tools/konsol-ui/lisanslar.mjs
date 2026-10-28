// Vite plugin for Konsol's new shell (DD-258): the minified bundle keeps no comments, so each output chunk
// starts with a banner that names every package bundled into it, with its version and copyright line,
// followed by the MIT permission notice. A bundled package under another licence stops the build (the same
// rule as tools/duzenleyici, DD-249).
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const PACKAGE_RE = /^(.*\/node_modules\/((?:@[^/]+\/)?[^/]+))\//;
const MIT = ` * Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
 * associated documentation files (the "Software"), to deal in the Software without restriction,
 * including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions: The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
 * WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS
 * OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 * CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.`;

function describe(dir) {
  const pkg = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
  if (pkg.license !== "MIT") throw new Error(`${pkg.name}: lisans MIT değil (${pkg.license})`);
  let copyright = "";
  for (const name of ["LICENSE", "LICENSE.md", "LICENSE.txt"]) {
    const file = join(dir, name);
    if (!existsSync(file)) continue;
    copyright = (/^Copyright .*$/m.exec(readFileSync(file, "utf8")) || [""])[0].trim();
    break;
  }
  if (!copyright) {
    const author = typeof pkg.author === "string" ? pkg.author : pkg.author?.name;
    copyright = author ? `Copyright (c) ${author}` : "Copyright (c) its authors";
  }
  return `${pkg.name} ${pkg.version} — ${copyright}`;
}

export function lisanslar() {
  return {
    name: "konsol-lisanslar",
    apply: "build",
    generateBundle(_options, bundle) {
      for (const chunk of Object.values(bundle)) {
        if (chunk.type !== "chunk") continue;
        const packages = new Map();
        for (const id of chunk.moduleIds) {
          const match = PACKAGE_RE.exec(id.replace(/\\/g, "/"));
          if (match && !packages.has(match[2])) packages.set(match[2], describe(match[1]));
        }
        if (!packages.size) continue;
        const lines = [...packages.values()].sort().map((p) => ` *   ${p}`).join("\n");
        chunk.code = `/*! Konsol (DD-258), built from Data/tools/konsol-ui (npm ci && npm run derle).
 * Bundled packages, all under the MIT license:
${lines}
 *
${MIT}
 */
${chunk.code}`;
      }
    },
  };
}
