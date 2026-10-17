// The phase 3 reads and writes (DD-258): Erişim's sections and the settings transaction with its dry run,
// through which every access change goes since rebuild phase 4 (the fixed rows, an application's access
// rows, WireGuard's planned actions). Paths and shapes come from sema.ts (generated from panel/master_api.py);
// every reply is checked before a page shows it, and a list item without its expected fields is left out.
import {
  YOLLAR,
  type Adlar,
  type AyarIstegi,
  type AyarPlani,
  type AyarSonucu,
  type GuvenlikDuvari,
  type KuralTaslagi,
  type Tamam,
} from "./sema";
import { getJson, postJson } from "./http";
import { isObject, isText, shaped } from "./konsol";

const isList = Array.isArray;
const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const isBool = (v: unknown): v is boolean => typeof v === "boolean";

export function isRule(v: unknown): v is KuralTaslagi {
  return (
    isObject(v) && isText(v.id) && isText(v.name) && (v.family === 4 || v.family === 6) && (v.scope === "wan" || v.scope === "tail") &&
    (v.proto === "tcp" || v.proto === "udp") && isNumber(v.port) && isText(v.source) && isBool(v.allow)
  );
}

function isPlan(v: unknown): v is AyarPlani {
  return isObject(v) && isText(v.revizyon) && isNumber(v.onay_sn) && isList(v.degisiklikler) && isList(v.etkiler) && isList(v.uyarilar) && isBool(v.uygulanabilir);
}

function cleanPlan(plan: AyarPlani): AyarPlani {
  return {
    ...plan,
    degisiklikler: plan.degisiklikler.filter((d) => isObject(d) && isText(d.alan) && isText(d.islem) && isText(d.nesne)),
    etkiler: plan.etkiler.filter(isText),
    uyarilar: plan.uyarilar.filter((u) => isObject(u) && isText(u.metin)),
  };
}

export async function planSettings(request: AyarIstegi): Promise<AyarPlani> {
  return cleanPlan(shaped<AyarPlani>(await postJson(YOLLAR.ayarlar_plan, request), isPlan));
}

export async function applySettings(request: AyarIstegi): Promise<AyarSonucu> {
  return shaped<AyarSonucu>(await postJson(YOLLAR.ayarlar_uygula, request), (v) => "pending" in v && (v.pending === null || isObject(v.pending)));
}

export async function confirmChange(id: string): Promise<Tamam> {
  return shaped<Tamam>(await postJson(YOLLAR.ayarlar_onayla, { id }), () => true);
}

export async function rollBackChange(id: string): Promise<Tamam> {
  return shaped<Tamam>(await postJson(YOLLAR.ayarlar_geri_al, { id }), () => true);
}

export async function discardChange(id: string): Promise<Tamam> {
  return shaped<Tamam>(await postJson(YOLLAR.ayarlar_birak, { id, confirm: "onayla" }), () => true);
}

export async function readFirewall(fresh = false): Promise<GuvenlikDuvari> {
  const value = shaped<GuvenlikDuvari>(await getJson(YOLLAR.guvenlik_duvari + (fresh ? "?yenile=1" : "")), (v) =>
    isText(v.revizyon) && isObject(v.denetim) && isList(v.kurallar) && isList(v.portlar));
  return {
    ...value,
    kurallar: value.kurallar.filter(isRule),
    // A fixed row (an application's raw or Tailscale port) names its access row (satir).
    portlar: value.portlar
      .filter((k) => isObject(k) && isText(k.ad) && isNumber(k.port) && isText(k.proto) && (k.aile === 4 || k.aile === 6) && isText(k.kapsam))
      .map((k) => ({ ...k, sabit: k.sabit === true, satir: isText(k.satir) && k.satir ? k.satir : null })),
    dinleyiciler: isList(value.dinleyiciler) ? value.dinleyiciler.filter((d) => isObject(d) && isNumber(d.port) && isText(d.proto)) : null,
    teknik: isList(value.teknik) ? value.teknik.filter((t) => isObject(t) && isText(t.kural) && isText(t.zincir)) : [],
    aglar: isList(value.aglar) ? value.aglar.filter((a) => isObject(a) && isText(a.arayuz)) : [],
    hatalar: isList(value.hatalar) ? value.hatalar.filter(isText) : [],
  };
}

export async function readNames(): Promise<Adlar> {
  const value = shaped<Adlar>(await getJson(YOLLAR.adlar), (v) => isText(v.revizyon) && isText(v.alan) && isList(v.adlar) && isList(v.kayitlar));
  return {
    ...value,
    // The managed names are read-only; each changes in its own row (satir: panel, paylasim or an access row).
    adlar: value.adlar
      .filter((a) => isObject(a) && isText(a.ad))
      .map((a) => ({ ...a, satir: isText(a.satir) && a.satir ? a.satir : null })),
    kayitlar: value.kayitlar.filter((r) => isObject(r) && isText(r.name) && isText(r.target) && isBool(r.enabled)),
    yonlendirme: value.yonlendirme === true,
    sunucular: isList(value.sunucular) ? value.sunucular.filter(isText) : [],
    hatalar: isList(value.hatalar) ? value.hatalar.filter(isText) : [],
  };
}
