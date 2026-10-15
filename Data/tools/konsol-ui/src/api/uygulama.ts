// App Store packages for the catalogue, an install and a package's settings (DD-148, DD-200, DD-210; phase
// 4a): every package with its konsol.json, the first-login account of a package that declares one, and the
// package's own API routes its form names (`oku`, `yaz`). Paths come from sema.ts; a package API's route is
// /api/uygulama/<id><route> with the route as its declaration checks it (form.ts).
import { YOLLAR, type Modul, type UygulamaHesabi } from "./sema";
import { getJson, postJson } from "./http";
import { isObject, isText, shaped } from "./konsol";

/** Every package, installed or not, with its App Store texts and form (GET /api/konsol/moduller). */
export async function readPackages(): Promise<Modul[]> {
  const v = shaped<{ items: unknown[] }>(await getJson(YOLLAR.moduller), (d) => Array.isArray(d.items));
  return v.items.filter((m): m is Modul => isObject(m) && isText(m.id) && typeof m.installed === "boolean");
}

/** The first-login account (PAKET_HESAP, DD-149): the temporary password only with `reveal` (audited). */
export async function readAccount(appId: string, reveal = false): Promise<UygulamaHesabi> {
  const params = new URLSearchParams({ id: appId });
  if (reveal) params.set("parola", "1");
  return shaped<UygulamaHesabi>(await getJson(`${YOLLAR.uygulama_hesabi}?${params.toString()}`), (v) => isText(v.user) && typeof v.temp === "boolean");
}

const packagePath = (id: string, route: string) => `/api/uygulama/${encodeURIComponent(id)}${route}`;

/** A package's settings as its form's `oku` route returns them (current values; never a password). */
export async function readPackageSettings(id: string, route: string): Promise<Record<string, unknown>> {
  const v = await getJson(packagePath(id, route));
  return isObject(v) ? v : {};
}

/** Only the changed fields go to the form's `yaz` route; a blank password is never sent. */
export async function writePackageSettings(id: string, route: string, values: Record<string, string>): Promise<Record<string, unknown>> {
  const v = await postJson(packagePath(id, route), values);
  return isObject(v) ? v : {};
}
