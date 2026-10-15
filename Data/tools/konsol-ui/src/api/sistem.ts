// Sistem's reads and actions (DD-266, phase 4a): repair and its log, the update, the Konsol account and this
// session, the reboot and the audit log. Paths and shapes come from sema.ts (generated from
// panel/master_api.py); a reply without its expected shape is an error, and a list item without its
// expected fields is left out.
import {
  YOLLAR,
  type Guncelleme,
  type GuncellemeBasladi,
  type HesapSonucu,
  type KayitSatiri,
  type Modul,
  type Onarim,
  type OnarimBasladi,
  type Oturum,
  type YenidenBaslatma,
} from "./sema";
import { ApiError, KONSOL_HEADERS, getJson, goToSignIn, postJson } from "./http";
import { isObject, isText, shaped } from "./konsol";

const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

/** The backend's own words from an error reply, or the status. */
async function errorOf(res: Response): Promise<{ message: string; signIn: boolean }> {
  let body: unknown = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  const message = isObject(body) && isText(body.error) ? body.error : `Sunucu yanıtı: HTTP ${res.status}`;
  return { message, signIn: isObject(body) && body.giris === true };
}

export async function readRepairReport(): Promise<Onarim> {
  const value = shaped<Onarim>(await getJson(YOLLAR.onarim), (v) => typeof v.baslatilabilir === "boolean" && typeof v.calisiyor === "boolean");
  const r = value.rapor;
  const report = isObject(r) && Array.isArray(r.adimlar) && isText(r.durum)
    ? { ...r, adimlar: r.adimlar.filter((s) => isObject(s) && isText(s.ad) && isText(s.durum)) }
    : null;
  return { ...value, kurulu: value.kurulu !== false, rapor: report };
}

export async function startRepairRun(kip: "onar" | "denetle"): Promise<OnarimBasladi> {
  return shaped(await postJson(YOLLAR.onarim_baslat, { kip }), (v) => isText(v.kip));
}

/** master-onar's journal for 72 hours or a week: a plain-text reply (route flag text). */
export async function readRepairLog(span: "72s" | "7g"): Promise<string> {
  const res = await fetch(`${YOLLAR.onarim_gunlugu}?sure=${span}`, { headers: KONSOL_HEADERS, credentials: "same-origin", cache: "no-store" });
  if (res.status === 401) {
    goToSignIn();
    throw new ApiError(401, "Oturum gerekli; yeniden giriş yapın.");
  }
  if (!res.ok) throw new ApiError(res.status, (await errorOf(res)).message);
  return res.text();
}

export function isUpdate(v: Record<string, unknown>): boolean {
  return isText(v.kurulu) && typeof v.yeni === "boolean" && isObject(v.is) && isText(v.is.durum) && typeof v.baslatilabilir === "boolean";
}

export async function readUpdate(fresh = false): Promise<Guncelleme> {
  return shaped<Guncelleme>(await getJson(YOLLAR.guncelleme + (fresh ? "?yenile=1" : "")), isUpdate);
}

export async function startUpdate(surum: string, commit: string): Promise<GuncellemeBasladi> {
  return shaped(await postJson(YOLLAR.guncelleme_baslat, { surum, commit }), (v) => isText(v.surum));
}

export async function readSession(): Promise<Oturum> {
  return shaped<Oturum>(await getJson(YOLLAR.oturum), (v) => isText(v.durum) && isText(v.kanal));
}

export async function createAccount(kullanici: string, parola: string): Promise<HesapSonucu> {
  return shaped(await postJson(YOLLAR.oturum_kur, { kullanici, parola }), (v) => isText(v.durum));
}

/** A new password; `eski` only on the internet channel. A wrong current password is a 401 without the
    sign-in mark (`giris`), shown on the form; an ended session goes to the sign-in page (http.ts). */
export async function changePassword(yeni: string, eski?: string): Promise<HesapSonucu> {
  return shaped(await postJson(YOLLAR.hesap_parola, eski === undefined ? { yeni } : { eski, yeni }), (v) => isText(v.durum));
}

export async function signOut(): Promise<void> {
  try {
    await postJson(YOLLAR.oturum_cikis, {});
  } catch {
    // the session may have ended already; the sign-in page follows either way
  }
}

export async function reboot(): Promise<YenidenBaslatma> {
  return shaped(await postJson(YOLLAR.yeniden_baslat, {}), (v) => isNumber(v.sure));
}

export async function readAudit(): Promise<KayitSatiri[]> {
  const value = shaped<{ items: unknown[] }>(await getJson(YOLLAR.islemler), (v) => Array.isArray(v.items));
  return value.items.filter((e): e is KayitSatiri =>
    isObject(e) && isNumber(e.at) && isText(e.source) && isText(e.action) && isText(e.detail) && typeof e.ok === "boolean" &&
    isText(e.user) && isText(e.client));
}

/** The packages with their konsol.json (names and the audit line templates, `gunluk`). */
export async function readModules(): Promise<Modul[]> {
  const value = shaped<{ items: unknown[] }>(await getJson(YOLLAR.moduller), (v) => Array.isArray(v.items));
  return value.items.filter((m): m is Modul => isObject(m) && isText(m.id));
}
