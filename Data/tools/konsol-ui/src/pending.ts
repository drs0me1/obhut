// The pending settings change in words (rebuild phase 5): what waits for its confirmation, for the banner on every
// page and İşlemler. The server names the change's subject (BekleyenDegisiklik): the local domain, an access row by
// its id, a fixed row (Konsol or Paylaşımlar), a WireGuard action; anything else is the firewall or the local names.
import { rowName } from "./access";
import type { BekleyenDegisiklik, Erisim, WireGuardEylemi } from "./api/sema";

const WIREGUARD: Record<WireGuardEylemi, (iface: string) => string> = {
  baslat: () => "WireGuard'ı aç",
  durdur: () => "WireGuard'ı kapat",
  "ag-ekle": () => "WireGuard ağı ekle",
  "ag-kaldir": (iface) => `${iface} ağını kaldır`,
  "ag-ac": (iface) => `${iface} ağını aç`,
  "ag-kapat": (iface) => `${iface} ağını kapat`,
  "yeniden-uret": (iface) => `${iface} anahtarını yeniden üret`,
};

/** "WireGuard'ı aç", "Erişim değişikliği · notlar.ev", "Yerel alan adı · ev → evim", … */
export function pendingTitle(change: BekleyenDegisiklik, erisim: Erisim | null): string {
  if (change.domain) return `Yerel alan adı · ${change.domain.old} → ${change.domain.new}`;
  if (change.wireguard) return (WIREGUARD[change.wireguard.eylem] ?? (() => "WireGuard değişikliği"))(change.wireguard.iface ?? "WireGuard");
  if (change.erisim) {
    const row = erisim?.hizmetler.find((h) => h.id === change.erisim);
    return row ? `Erişim değişikliği · ${rowName(row, erisim?.alan ?? "")}` : "Erişim değişikliği";
  }
  if (change.web) return "Erişim değişikliği · Konsol ya da Paylaşımlar";
  return "Güvenlik duvarı ya da yerel adlar";
}
