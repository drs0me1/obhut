// A package's install and settings form (DD-210) from its konsol.json declaration, read the way the current
// Konsol reads it (konsol.js formOf): generic field kinds (text, password, folder), never an application's
// name. The client checks only what the declaration says (required, length, pattern); the package's worker
// checks everything again and its refusal is shown in its own words.
import { isObject, isText } from "../../api/konsol";
import { iconOf, type IconName } from "../../components/icons";

export type FieldKind = "metin" | "parola" | "klasor";

export interface FormField {
  ad: string;
  tur: FieldKind;
  etiket: string;
  varsayilan: string;
  desen: string;
  enAz: number | null;
  enCok: number | null;
  ipucu: string;
  ayarIpucu: string;
}

export interface PackageForm {
  fields: FormField[];
  kurBaslik: string;
  kurAlt: string;
  kurNot: string;
  ayarBaslik: string;
  ayarAlt: string;
  ayarNot: string;
  /** The package API's routes for the settings mode ("/durum", "/ayar"); "" when it has none. */
  oku: string;
  yaz: string;
}

const KINDS = new Set<FieldKind>(["metin", "parola", "klasor"]);
const text = (v: unknown) => (isText(v) ? v : "");
const count = (v: unknown) => (Number.isInteger(v) && (v as number) > 0 && (v as number) <= 4096 ? (v as number) : null);
const route = (v: unknown) => (isText(v) && /^\/[a-z]{1,16}$/.test(v) ? v : "");
// A default the installer did not fill in (an unrendered "__DOWNLOADS_PATH__") is no default.
const filled = (v: string) => (/__[A-Z0-9_]+__/.test(v) ? "" : v);

export function formOf(konsol: unknown): PackageForm | null {
  const f = isObject(konsol) ? konsol.form : null;
  if (!isObject(f) || !Array.isArray(f.alanlar)) return null;
  const fields = f.alanlar
    .filter((a): a is Record<string, unknown> => isObject(a) && isText(a.ad) && /^[a-z_]{1,32}$/.test(a.ad) && KINDS.has(a.tur as FieldKind))
    .map((a) => ({
      ad: a.ad as string,
      tur: a.tur as FieldKind,
      etiket: text(a.etiket) || (a.ad as string),
      varsayilan: filled(text(a.varsayilan)),
      desen: text(a.desen),
      enAz: count(a.en_az),
      enCok: count(a.en_cok),
      ipucu: text(a.ipucu),
      ayarIpucu: text(a.ayar_ipucu),
    }));
  if (!fields.length) return null;
  return {
    fields,
    kurBaslik: text(f.kur_baslik),
    kurAlt: text(f.kur_alt),
    kurNot: text(f.kur_not),
    ayarBaslik: text(f.ayar_baslik),
    ayarAlt: text(f.ayar_alt),
    ayarNot: text(f.ayar_not),
    oku: route(f.oku),
    yaz: route(f.yaz),
  };
}

/** The declared pattern as a whole-value test; a pattern this browser cannot read is not checked here. */
function matches(pattern: string, value: string): boolean {
  if (!pattern) return true;
  try {
    return new RegExp(`^(?:${pattern})$`, "u").test(value);
  } catch {
    return true;
  }
}

/** Why a field's value cannot be sent ("" when it can). In the settings mode a blank password keeps the
    stored one; a repeat must match its password. */
export function fieldProblem(f: FormField, value: string, repeat: string, install: boolean): string {
  const v = f.tur === "metin" ? value.trim() : value;
  if (f.tur === "parola") {
    if (!v && !install) return repeat ? "Parolalar aynı değil." : "";
    if (!v) return "Parolayı yazın.";
  } else if (!v) return f.tur === "klasor" ? "Bir klasör seçin." : "Bu alan gerekli.";
  const length = [...v].length;
  if (f.enAz !== null && length < f.enAz) return `En az ${f.enAz} karakter olmalı.`;
  if (f.enCok !== null && length > f.enCok) return `En çok ${f.enCok} karakter olabilir.`;
  if (f.tur === "metin" && !matches(f.desen, v)) return f.ipucu ? `Geçersiz değer. ${f.ipucu}` : "Geçersiz değer.";
  if (f.tur === "parola" && v !== repeat) return "Parolalar aynı değil.";
  return "";
}

// ---- a package's App Store texts (konsol.json): description, what installing does, facts
export interface PackageTexts {
  name: string;
  sub: string;
  description: string;
  icon: string;
  will: { icon: IconName; text: string }[];
  facts: string[];
}

export function textsOf(id: string, konsol: unknown): PackageTexts {
  const k = isObject(konsol) ? konsol : {};
  const will = Array.isArray(k.neler)
    ? k.neler.filter((p): p is [string, string] => Array.isArray(p) && p.length === 2 && isText(p[0]) && isText(p[1])).map(([icon, t]) => ({ icon: iconOf(icon, "info"), text: t }))
    : [];
  return {
    name: text(k.ad) || id,
    sub: text(k.alt),
    description: text(k.aciklama),
    icon: text(k.simge),
    will,
    facts: Array.isArray(k.notlar) ? k.notlar.filter(isText) : [],
  };
}
