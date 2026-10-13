// Small formatting helpers. Unknown values are "—", never 0.
export const UNKNOWN = "—";

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

/** Unix seconds as the local hh:mm. */
export function clock(unixSeconds: number | null | undefined): string {
  if (typeof unixSeconds !== "number" || !Number.isFinite(unixSeconds) || unixSeconds <= 0) return UNKNOWN;
  return clockFormat.format(new Date(unixSeconds * 1000));
}

/** Turkish-aware lower case: "İ" → "i", "I" → "ı". */
export const fold = (text: string): string => text.toLocaleLowerCase("tr-TR");
