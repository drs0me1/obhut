// How Erişim (DD-258, phase 3) names things everywhere: where a warning's "Düzelt" leads, what kind of
// thing a publication candidate is, a publication's state in words, and the name rules the Yayınla flow
// checks before it asks the server (the server checks them again).
import { accessRoute } from "./sections";
import type { Uyari, YayinAdayi } from "./api/sema";

/** Where a warning is fixed: its publication in the Yayınla flow (Adresler), the application's page (an
    Erişim row's id is its application's id) or the Tailscale tab; without a target, Erişim itself. */
export function fixRoute(fix: Uyari["duzelt"]): string {
  if (!fix) return accessRoute();
  if (fix.bolum === "uygulama" && fix.hedef) return "/uygulamalar/" + fix.hedef;
  if (fix.bolum === "tailscale") return accessRoute("tailscale");
  return accessRoute("adresler", fix.hedef || "sec");
}

export const CANDIDATE_KIND: Record<YayinAdayi["tur"], string> = {
  konsol: "Konsol",
  konteyner: "Konteyner",
  elle: "Elle adres",
  paylasim: "WebDAV",
};

/** A publication row's state (master_publications.status) in words. */
export function publicationState(c: Pick<YayinAdayi, "durum" | "servis" | "internet">): string {
  if (!c.servis) return "Yayımlanmadı";
  switch (c.durum) {
    case "ready":
      return "Sertifika hazır";
    case "pending":
      return "Sertifika hazırlanıyor…";
    case "error":
      return "Yayın doğrulanamadı";
    case "http":
      return "Eski HTTP erişimi";
    case "disabled":
      return "İnternet kapalı";
    default:
      return c.internet ? "Durum bilinmiyor" : "İnternet kapalı";
  }
}

/** A full public host name: no URL, IP, port or path. */
export const HOST_RE = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:[a-z]{2,63}|xn--[a-z0-9-]+)$/;
/** A tailnet name's first label (<ad>.<alan>). */
export const LOCAL_RE = /^[a-z][a-z0-9-]{0,30}$/;
/** A local domain (Konsol answers at panel.<alan>). */
export const DOMAIN_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

/** The server's own choice of a tailnet name for a container (master_yayin.default_local), shown as the
    starting value; the request leaves `yerel` out while it is unchanged, so the server's rule decides. */
export function defaultLocal(name: string): string {
  let text = name.toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "");
  if (!text || !/^[a-z]/.test(text)) text = "k-" + text;
  return text.slice(0, 31).replace(/-+$/, "") || "konteyner";
}

/** A public name as the operator typed it: trimmed, lower case, without a final dot. */
export const cleanHost = (text: string): string => text.trim().toLowerCase().replace(/\.$/, "");

/** Why a public name cannot be used, or "" when it can. */
export function hostProblem(text: string): string {
  const host = cleanHost(text);
  if (!host) return "İnternet adını yazın (ör. uygulama.example.org).";
  return HOST_RE.test(host) ? "" : "Tam alan adını girin; URL, IP, port veya yol eklemeyin.";
}
