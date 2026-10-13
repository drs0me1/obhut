// Small formatting helpers. Unknown values are "—", never 0.
export const UNKNOWN = "—";

const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

/** "2026.08.06-v2-242" → "v2-242"; anything else as it is. */
export function shortVersion(version: string | null | undefined): string {
  if (!version) return UNKNOWN;
  const match = /(v\d+-\d+)\s*$/.exec(version);
  return match?.[1] ?? version;
}

/** Seconds as m:ss. */
export function countdown(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

const clockFormat = new Intl.DateTimeFormat("tr-TR", { hour: "2-digit", minute: "2-digit" });
const dateTimeFormat = new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" });
const percentFormat = new Intl.NumberFormat("tr-TR", { style: "percent", maximumFractionDigits: 0 });

/** Unix seconds as the local hh:mm. */
export function clock(unixSeconds: number | null | undefined): string {
  if (!isNumber(unixSeconds) || unixSeconds <= 0) return UNKNOWN;
  return clockFormat.format(new Date(unixSeconds * 1000));
}

/** Unix seconds as "8 Ekim 14:02". */
export function dateTime(unixSeconds: number | null | undefined): string {
  if (!isNumber(unixSeconds) || unixSeconds <= 0) return UNKNOWN;
  return dateTimeFormat.format(new Date(unixSeconds * 1000));
}

/** Turkish-aware lower case: "İ" → "i", "I" → "ı". */
export const fold = (text: string): string => text.toLocaleLowerCase("tr-TR");

const decimal = (v: number, digits: number) => v.toFixed(digits).replace(".", ",");

/** Bytes the way the current Konsol shows them: 1024-based, one decimal from GB up ("7,8 GB", "664 MB"). */
export function bytes(value: number | null | undefined): string {
  if (!isNumber(value) || value < 0) return UNKNOWN;
  if (value === 0) return "0 B";
  if (value >= 1024 ** 4) return decimal(value / 1024 ** 4, 2) + " TB";
  if (value >= 1024 ** 3) return decimal(value / 1024 ** 3, 1) + " GB";
  if (value >= 1024 ** 2) return Math.round(value / 1024 ** 2) + " MB";
  return Math.max(1, Math.round(value / 1024)) + " KB";
}

/** Bytes per second ("38 KB/s"). */
export function rate(value: number | null | undefined): string {
  const text = bytes(value);
  return text === UNKNOWN ? UNKNOWN : text + "/s";
}

/** A percentage given as 0–100, Turkish style ("%2"). */
export function percent(value: number | null | undefined): string {
  if (!isNumber(value) || value < 0) return UNKNOWN;
  return percentFormat.format(value / 100);
}

/** Uptime in seconds: "5 gün", "3 sa 12 dk", "12 dk". */
export function uptime(seconds: number | null | undefined): string {
  if (!isNumber(seconds) || seconds <= 0) return UNKNOWN;
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (days) return `${days} gün`;
  if (hours) return `${hours} sa ${minutes} dk`;
  return `${minutes} dk`;
}

/** How long ago a server time was, measured on the server's clock (`now` in Unix seconds). */
export function since(unixSeconds: number | null | undefined, now: number): string {
  if (!isNumber(unixSeconds) || unixSeconds <= 0) return UNKNOWN;
  const age = Math.max(0, Math.floor(now - unixSeconds));
  if (age < 90) return "az önce";
  if (age < 7200) return `${Math.floor(age / 60)} dakika önce`;
  if (age < 172800) return `${Math.floor(age / 3600)} saat önce`;
  return `${Math.floor(age / 86400)} gün önce`;
}
