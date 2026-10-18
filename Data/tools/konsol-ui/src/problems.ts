// What needs the operator (rebuild phase 5): one list for Uyarılar (the page the top bar's count opens) and the
// count itself, so both say the same thing. A failed or warning health check leads to Sistem →
// Sağlık (its repair is there), an Erişim warning to where its `duzelt` says (an access row's sheet, an
// application, the Tailscale tab), an application that does not run fully to its page. A newer image of an
// application is news, not a problem: it is listed (tone "accent") but not counted in the chip.
import { computed } from "vue";
import type { Tone } from "./components/ui/types";
import { apps, checkLevel, live } from "./live";
import { fixRoute } from "./access";
import { systemRoute } from "./sections";

export interface Problem {
  key: string;
  kind: "saglik" | "erisim" | "uygulama";
  tone: Extract<Tone, "danger" | "warning" | "accent">;
  title: string;
  detail: string;
  /** Where it is looked at and fixed. */
  to: string;
  /** The link's words. */
  label: string;
}

const appPage = (ad: string) => "/uygulamalar/" + encodeURIComponent(ad);

/** The name of the thing an Erişim warning is about: Konsol, Paylaşımlar, an application or its row. */
const serviceNames = computed(() => {
  const names = new Map<string, string>([["panel", "Konsol"], ["tailscale", "Tailscale"], ["paylasim", "Paylaşımlar"]]);
  for (const row of live.erisim?.hizmetler ?? []) if (!names.has(row.id)) names.set(row.id, row.uygulama ?? row.ad);
  return names;
});

const RANK: Record<Problem["tone"], number> = { danger: 0, warning: 1, accent: 2 };

/** Every problem, the most serious first (otherwise in the order the server reports them). */
export const problemList = computed<Problem[]>(() => {
  const out: Problem[] = [];
  for (const check of live.saglik?.checks ?? []) {
    const level = checkLevel(check.status);
    if (level === "ok") continue;
    out.push({ key: "saglik:" + check.id, kind: "saglik", tone: level, title: check.name || check.id, detail: check.detail, to: systemRoute("saglik"),
      label: "Sağlık'ta incele" });
  }
  (live.uyarilar ?? []).forEach((u, i) => {
    const service = serviceNames.value.get(u.hizmet);
    out.push({ key: `erisim:${i}`, kind: "erisim", tone: u.seviye === "bad" ? "danger" : "warning", title: u.metin, detail: service ? `Erişim · ${service}` : "Erişim",
      to: fixRoute(u.duzelt ?? null), label: u.duzelt?.bolum === "uygulama" ? "Uygulamaya git" : "Erişim'de incele" });
  });
  for (const app of apps.value ?? []) {
    if (app.durum === "hata") {
      out.push({ key: "uygulama:" + app.ad, kind: "uygulama", tone: "danger", title: `${app.ad} çalışmıyor`, detail: "Servislerinin durumu ve günlüğü uygulamanın sayfasında.",
        to: appPage(app.ad), label: "Uygulamaya git" });
    } else if (app.durum === "kismen") {
      out.push({ key: "uygulama:" + app.ad, kind: "uygulama", tone: "warning", title: `${app.ad} kısmen çalışıyor`, detail: "Servislerinden en az biri durmuş.",
        to: appPage(app.ad), label: "Uygulamaya git" });
    }
    if (app.guncelleme === "yeni") {
      const image = app.servisler.find((s) => s.guncelleme === "yeni")?.imaj ?? "";
      out.push({ key: "guncelleme:" + app.ad, kind: "uygulama", tone: "accent", title: `${app.ad} için yeni imaj var`,
        detail: image ? `${image} etiketinin yeni yapısı yayımlandı.` : "İmajının yeni yapısı yayımlandı.", to: appPage(app.ad), label: "Uygulamaya git" });
    }
  }
  return out.map((p, i) => [p, i] as const).sort((a, b) => RANK[a[0].tone] - RANK[b[0].tone] || a[1] - b[1]).map(([p]) => p);
});

/** The top bar's chip: how many problems (news left out) and how serious; null while health is unknown. */
export const problemSummary = computed(() => {
  if (!live.saglik) return null;
  const real = problemList.value.filter((p) => p.tone !== "accent");
  const level = real.some((p) => p.tone === "danger") ? "danger" : real.length ? "warning" : "ok";
  return { count: real.length, level } as const;
});
