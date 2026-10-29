<!-- One container's page (DD-294; #/podman/konteyner/<ad>), whoever installed it: its state, who runs it and its
     actions (ContainerActions; an application's container leads to the application), then Özet (state, image,
     resources, ports, mounts with the way to them in Dosyalar, networks, labels) and Günlük (its last lines from
     where its log driver writes them, live on request). Never its environment or command line. The page reads
     itself again when Podman's state changes (the live "podman" topic) and every 10 s while shown, for its
     resources; a removed container leaves the page for Podman. -->
<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { RouterLink, useRoute, useRouter } from "vue-router";
import Card from "../components/ui/Card.vue";
import EmptyState from "../components/ui/EmptyState.vue";
import StatusPill from "../components/ui/StatusPill.vue";
import Tabs from "../components/ui/Tabs.vue";
import type { Tone } from "../components/ui/types";
import ContainerActions from "./podman/ContainerActions.vue";
import LogTab from "./app/LogTab.vue";
import { managerText, readContainer } from "../api/podman";
import { ApiError } from "../api/http";
import { live, serverNow } from "../live";
import { usePageHead } from "../page";
import { appRoute } from "../router";
import { filesRoute } from "../sections";
import { UNKNOWN, bytes, date, percent, uptime } from "../format";
import type { KonteynerAyrintisi } from "../api/sema";

const route = useRoute();
const router = useRouter();
const name = computed(() => String(route.params.ad ?? ""));
usePageHead(() => ({ title: name.value, parent: { label: "Podman", to: "/podman" } }));

const detail = ref<KonteynerAyrintisi | null>(null);
const missing = ref("");
const loadError = ref("");
let seq = 0;

async function load(): Promise<void> {
  const mine = ++seq;
  try {
    const value = await readContainer(name.value);
    if (mine !== seq) return;
    detail.value = value;
    missing.value = "";
    loadError.value = "";
  } catch (err) {
    if (mine !== seq) return;
    if (err instanceof ApiError && err.status === 404) {
      missing.value = "Podman bu adla bir konteyner bilmiyor; kaldırılmış olabilir.";
      detail.value = null;
    } else loadError.value = err instanceof Error ? err.message : String(err);
  }
}

watch(name, () => {
  detail.value = null;
  void load();
});
watch(() => live.podmanSurumu, () => void load());
let timer: number | undefined;
onMounted(() => {
  void load();
  timer = window.setInterval(() => {
    if (!document.hidden) void load();
  }, 10000);
});
onBeforeUnmount(() => {
  clearInterval(timer);
  seq += 1;
});

function done(action: string, ok: boolean): void {
  if (ok && action === "kaldir") {
    void router.replace("/podman");
    return;
  }
  void load();
}

// ---- what the page says
const STATES: Record<string, { text: string; tone: Tone; dot?: boolean }> = {
  running: { text: "Çalışıyor", tone: "ok", dot: true },
  exited: { text: "Durdu", tone: "neutral" },
  stopped: { text: "Durdu", tone: "neutral" },
  created: { text: "Başlatılmadı", tone: "neutral" },
  paused: { text: "Duraklatıldı", tone: "neutral" },
};
const state = computed(() => {
  const d = detail.value;
  if (!d) return null;
  if (d.durum === "running" && d.saglik === "unhealthy") return { text: "Sağlıksız", tone: "warning" as Tone, dot: true };
  return STATES[d.durum] ?? { text: d.durum || UNKNOWN, tone: "neutral" as Tone };
});

const description = computed(() => {
  const d = detail.value;
  if (!d) return "";
  return [managerText(d.yonetim), d.imaj].filter(Boolean).join(" · ");
});

const TABS = [
  { id: "ozet", label: "Özet" },
  { id: "gunluk", label: "Günlük" },
];

const LOG_SOURCE: Record<KonteynerAyrintisi["gunluk_kaynagi"], string> = {
  journald: "systemd günlüğü (journald)",
  birim: "Biriminin günlüğü",
  dosya: "Günlük dosyası",
  yok: "Günlük tutulmuyor",
};

const portText = (p: KonteynerAyrintisi["portlar"][number]) =>
  `${p.host_ip ? p.host_ip + ":" : ""}${p.host_port} → ${p.container_port}/${p.protocol || "tcp"}`;
const SCOPES: Record<string, string> = { local: "Yalnız bu sunucu", tailscale: "Tailscale", public: "İnternet", other: "Başka bir adres" };
/** Where a published port is reached from. DD-294: the container guard closes the internet to a container that is not an
    application's (an application's port opens there only through its access row). */
function scopeText(p: KonteynerAyrintisi["portlar"][number]): string {
  if (p.scope === "public" && detail.value?.yonetim.tur !== "uygulama") {
    return p.host_ip && !["0.0.0.0", "::"].includes(p.host_ip) ? "İnternete kapalı (koruma)" : "Tailscale · internete kapalı (koruma)";
  }
  return SCOPES[p.scope ?? ""] ?? UNKNOWN;
}

/** A mount's way into Dosyalar: a folder under /srv opens in Sunucu klasörleri, any other in Sistem dosyaları. */
const root = computed(() => live.kaynaklar?.root ?? "/srv");
function mountRoute(source: string): string {
  if (!source.startsWith("/")) return "";
  const base = root.value.replace(/\/+$/, "");
  if (source === base || source.startsWith(base + "/")) return filesRoute("srv", { yol: source.slice(base.length + 1) });
  return filesRoute("sistem", { yol: source.replace(/^\/+/, "") });
}
const uptimeText = computed(() => (detail.value?.durum === "running" && detail.value.basladi ? uptime(serverNow() - detail.value.basladi) : UNKNOWN));
</script>

<template>
  <div class="page-body container-page">
    <header class="app-head" :data-konteyner="name">
      <div class="app-head-main">
        <div class="app-head-text">
          <div class="app-title">
            <h1 tabindex="-1" class="mono">{{ name }}</h1>
            <StatusPill v-if="state" :tone="state.tone" :dot="state.dot" data-testid="container-state">{{ state.text }}</StatusPill>
          </div>
          <p class="page-desc" data-testid="container-desc">{{ description }}</p>
        </div>
      </div>
    </header>
    <ContainerActions v-if="detail" :name="detail.ad" :state="detail.durum" :manager="detail.yonetim" :busy="detail.is" @done="done" />
    <p v-if="loadError" class="notice notice-warning" role="alert" data-testid="load-error">{{ loadError }}</p>

    <section v-if="missing" class="card" aria-label="Konteyner bulunamadı">
      <EmptyState title="Bu konteyner yok" :text="missing" icon="box">
        <RouterLink to="/podman" class="btn btn-secondary">Podman'a dön</RouterLink>
      </EmptyState>
    </section>

    <Tabs v-else-if="detail" :tabs="TABS" :label="`${name} bölümleri`" param="sekme">
      <template #default="{ active }">
        <div v-if="active === 'ozet'" class="container-summary" data-testid="container-summary">
          <div class="tab-grid">
            <Card title="Durum" :level="3" data-testid="container-facts">
              <dl class="facts">
                <dt>Durum</dt><dd>{{ state?.text }}<template v-if="detail.saglik"> · sağlık: {{ detail.saglik }}</template></dd>
                <dt>Çalışma süresi</dt><dd>{{ uptimeText }}</dd>
                <dt>Oluşturma</dt><dd>{{ date(detail.olusturuldu) }}</dd>
                <dt>Yeniden başlama</dt><dd>{{ detail.yeniden_baslama }} kez · ilke: {{ detail.politika || "yok" }}</dd>
                <template v-if="detail.durum !== 'running'"><dt>Çıkış kodu</dt><dd>{{ detail.cikis_kodu }}</dd></template>
                <template v-if="detail.hata"><dt>Hata</dt><dd class="warn-text">{{ detail.hata }}</dd></template>
              </dl>
            </Card>
            <Card title="Yönetim" :level="3" data-testid="container-manager">
              <dl class="facts">
                <dt>Çalıştıran</dt>
                <dd>
                  <RouterLink v-if="detail.yonetim.tur === 'uygulama'" :to="appRoute(detail.yonetim.ad)">{{ managerText(detail.yonetim) }}</RouterLink>
                  <template v-else>{{ managerText(detail.yonetim) }}</template>
                </dd>
                <template v-if="detail.yonetim.dosya"><dt>Quadlet dosyası</dt><dd class="mono wrap">{{ detail.yonetim.dosya }}</dd></template>
                <template v-if="detail.pod"><dt>Pod</dt><dd>{{ detail.pod }}</dd></template>
                <dt>İmaj</dt><dd class="mono wrap">{{ detail.imaj || UNKNOWN }}</dd>
                <dt>İmaj kimliği</dt><dd class="mono">{{ detail.imaj_id || UNKNOWN }}</dd>
              </dl>
            </Card>
            <Card title="Kaynak" :level="3" data-testid="container-usage">
              <dl class="facts">
                <dt>İşlemci</dt><dd>{{ detail.durum === "running" ? percent(detail.cpu) : UNKNOWN }}</dd>
                <dt>Bellek</dt><dd>{{ detail.durum === "running" ? bytes(detail.bellek) : UNKNOWN }}</dd>
                <dt>Ağ kipi</dt><dd>{{ detail.ag_kipi || UNKNOWN }}</dd>
              </dl>
            </Card>
          </div>

          <section class="card table-card" aria-labelledby="ky-portlar" data-testid="container-ports">
            <h2 id="ky-portlar" class="card-title">Portlar</h2>
            <div v-if="detail.portlar.length" class="table-wrap">
              <table class="data-table">
                <thead><tr><th scope="col">Yayın</th><th scope="col">Erişim</th></tr></thead>
                <tbody>
                  <tr v-for="(p, i) in detail.portlar" :key="i">
                    <th scope="row" class="mono">{{ portText(p) }}</th>
                    <td data-label="Erişim">{{ scopeText(p) }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p v-else class="meter-note">Yayımlanan port yok.</p>
          </section>

          <section class="card table-card" aria-labelledby="ky-baglama" data-testid="container-mounts">
            <h2 id="ky-baglama" class="card-title">Bağlamalar</h2>
            <div v-if="detail.baglamalar.length" class="table-wrap">
              <table class="data-table">
                <thead><tr><th scope="col">Konteynerde</th><th scope="col">Sunucuda</th><th scope="col">Tür</th><th scope="col">İzin</th></tr></thead>
                <tbody>
                  <tr v-for="(m, i) in detail.baglamalar" :key="i">
                    <th scope="row" class="mono wrap">{{ m.hedef }}</th>
                    <td data-label="Sunucuda" class="mono wrap">
                      <RouterLink v-if="mountRoute(m.kaynak)" :to="mountRoute(m.kaynak)">{{ m.kaynak }}</RouterLink>
                      <template v-else>{{ m.kaynak || m.ad || UNKNOWN }}</template>
                    </td>
                    <td data-label="Tür">{{ m.tur === "volume" ? `Birim${m.ad ? " · " + m.ad : ""}` : m.tur === "bind" ? "Klasör" : m.tur || UNKNOWN }}</td>
                    <td data-label="İzin">{{ m.salt_okunur ? "Salt okunur" : "Okuma-yazma" }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p v-else class="meter-note">Bağlı klasör ya da birim yok.</p>
          </section>

          <section class="card table-card" aria-labelledby="ky-ag" data-testid="container-networks">
            <h2 id="ky-ag" class="card-title">Ağlar</h2>
            <div v-if="detail.aglar.length" class="table-wrap">
              <table class="data-table">
                <thead><tr><th scope="col">Ağ</th><th scope="col">IPv4</th><th scope="col">IPv6</th></tr></thead>
                <tbody>
                  <tr v-for="a in detail.aglar" :key="a.ad">
                    <th scope="row" class="mono">{{ a.ad }}</th>
                    <td data-label="IPv4" class="mono">{{ a.ipv4 || UNKNOWN }}</td>
                    <td data-label="IPv6" class="mono">{{ a.ipv6 || UNKNOWN }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p v-else class="meter-note">{{ detail.ag_kipi === "host" ? "Sunucunun ağını kullanıyor (host)." : "Ağa bağlı değil." }}</p>
          </section>

          <details v-if="detail.etiketler.length" class="card label-card" data-testid="container-labels">
            <summary class="card-title">Etiketler <span class="meter-note">{{ detail.etiketler.length }}</span></summary>
            <dl class="facts">
              <template v-for="e in detail.etiketler" :key="e.ad"><dt class="mono wrap">{{ e.ad }}</dt><dd class="mono wrap">{{ e.deger }}</dd></template>
            </dl>
          </details>
        </div>

        <div v-else-if="active === 'gunluk'" data-testid="container-log">
          <p class="meter-note">Kaynak: {{ LOG_SOURCE[detail.gunluk_kaynagi] }}</p>
          <LogTab v-if="detail.gunluk_kaynagi !== 'yok'" :container="detail.ad" />
          <EmptyState v-else title="Bu konteynerin günlüğü tutulmuyor" text="Günlük sürücüsü 'none' ya da tanınmayan bir sürücü." icon="lines" />
        </div>
      </template>
    </Tabs>
    <p v-else-if="!loadError" class="meter-note" role="status">Okunuyor…</p>
  </div>
</template>
