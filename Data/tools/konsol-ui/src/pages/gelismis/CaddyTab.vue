<!-- Gelişmiş → Caddy: the effective sites as Caddy serves them (GET /api/konsol/gelismis, the settings view's
     reading of the Caddyfile and the packages' sites): each address with what it is, where its paths lead,
     whose it is and how it is reached; then the raw files (?ham=1). Changes are made in Erişim. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import StatusPill from "../../components/ui/StatusPill.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import RawFiles from "./RawFiles.vue";
import { accessRoute } from "../../sections";
import { live } from "../../live";
import type { Advanced, CaddyRoute } from "../../api/gelismis";

const props = defineProps<{ data: Advanced }>();

const entries = computed(() => props.data.caddy.entries);
const isIpPort = (a: string) => /^\d+\.\d+\.\d+\.\d+:\d+$/.test(a);
const names = computed(() => entries.value.filter((e) => !isIpPort(e.address)).length);

/** A package's name from the application list ("torrent" → "qBittorrent"); otherwise the source itself. */
function packageName(id: string): string {
  return live.uygulamalar?.items.find((a) => a.modul === id)?.ad ?? id;
}
function owner(source: string): string {
  if (source === "base" || source === "panel-wan") return "Temel";
  if (source === "paylasim-wan") return "Paylaşımlar";
  return packageName(source.replace(/-wan$/, ""));
}
// DD-202: a package's public site is "<id>-wan"; its name comes from the package.
function describe(e: Advanced["caddy"]["entries"][number]): string {
  if (e.access === "wan") {
    const what = e.source === "panel-wan" ? "Sunucu yönetim paneli · internet girişi"
      : e.source === "paylasim-wan" ? "İnternet üzerinden seçili klasör paylaşımları"
      : `${packageName(e.source.replace(/-wan$/, ""))} · kendi girişiyle`;
    return what;
  }
  const extra = isIpPort(e.address) ? " · ad çözmeyen cihazlar için (ör. Infuse)" : "";
  if (e.source === "base") return (e.address.startsWith("panel.") ? "Sunucu yönetim paneli" : "Temel servis") + extra;
  return packageName(e.source) + extra;
}
function target(r: CaddyRoute): string {
  if (r.kind === "proxy") return r.to;
  if (r.kind === "files") return "sayfa dosyaları";
  if (r.kind === "respond") return `sabit yanıt “${r.to}”`;
  if (r.kind === "redirect") return `yönlendirme → ${r.to}`;
  return r.to || r.kind;
}
const access = (e: Advanced["caddy"]["entries"][number]) =>
  e.access === "wan"
    ? { text: "İnternet", tone: e.scheme === "https" ? ("accent" as const) : ("warning" as const) }
    : { text: "Tailscale", tone: "ok" as const };
const scheme = (e: Advanced["caddy"]["entries"][number]) =>
  e.scheme === "https" ? "HTTPS" : e.scheme === "http" ? (e.access === "wan" ? "HTTP · şifresiz" : "HTTP") : e.scheme.toUpperCase() || "—";
const plainWan = computed(() => entries.value.some((e) => e.access === "wan" && e.scheme !== "https"));
const fileCount = computed(() => `${props.data.caddy.raw.length} dosya`);
</script>

<template>
  <div class="advanced-tab" data-testid="caddy">
    <section class="card" aria-labelledby="caddy-baslik">
      <div class="card-head">
        <h2 id="caddy-baslik" class="card-title">Web adresleri</h2>
        <span class="meter-note" data-testid="caddy-count">Caddy · {{ names }} ad, {{ entries.length - names }} IP adresi</span>
      </div>
      <div v-if="entries.length" class="table-wrap">
        <table class="data-table caddy-table">
          <thead>
            <tr>
              <th scope="col">Adres</th>
              <th scope="col">Nereye gider</th>
              <th scope="col">Kaynak</th>
              <th scope="col">Erişim</th>
              <th scope="col">Şema</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(e, i) in entries" :key="`${e.address}:${i}`" :data-adres="e.address">
              <th scope="row" class="col-main">
                <strong class="mono wrap">{{ e.address }}</strong>
                <span class="cell-sub">{{ describe(e) }}</span>
              </th>
              <td data-label="Nereye gider">
                <ul class="route-list">
                  <li v-for="(r, n) in e.routes" :key="n">
                    <span v-if="r.path || e.routes.length > 1" class="route-path mono">{{ r.path || "diğer" }}</span>
                    <span v-if="r.path || e.routes.length > 1" class="route-arrow" aria-hidden="true">→</span>
                    <span :class="{ mono: r.kind === 'proxy' || r.kind === 'redirect' }">{{ target(r) }}</span>
                  </li>
                  <li v-if="!e.routes.length" class="muted">Yönlendirme yok</li>
                </ul>
              </td>
              <td data-label="Kaynak">{{ owner(e.source) }}</td>
              <td data-label="Erişim"><StatusPill :tone="access(e).tone">{{ access(e).text }}</StatusPill></td>
              <td data-label="Şema" :class="{ 'warn-text': e.access === 'wan' && e.scheme !== 'https' }">{{ scheme(e) }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <EmptyState v-else title="Caddy'de site yok" text="Yapılandırma dosyalarında bir site bulunamadı." icon="globe" />
      <p class="meter-note">
        Konsol'un Tailscale adresi her zaman açıktır. İnternet etiketi Erişim → Adresler'de açılan internet yayınını gösterir.
        <template v-if="plainWan"> İnternet üzerinden HTTP parolaları ve dosyaları şifrelemez.</template>
      </p>
      <RouterLink :to="accessRoute('adresler')" class="section-link">Adresleri Erişim'de değiştir</RouterLink>
    </section>
    <RawFiles :files="data.caddy.raw" :summary="`Caddyfile ve paketlerin siteleri · ${fileCount}`" />
  </div>
</template>
