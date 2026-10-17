<!-- Genel Bakış (rebuild phase 5): what needs attention first, each with the link to where it is fixed (problems.ts:
     a health check → Sistem → Sağlık, an Erişim warning → its access row, tab or application, an application that
     does not run fully or has a newer image → its page), or a calm "Her şey yolunda"; then the applications (state,
     address, "Aç" for one with an address, "Ayrıntı"), the access summary (Tailscale names, internet names, raw
     ports open to the internet and on Tailscale, WireGuard; a chip for whatever is open to the internet, each
     leading to its row in Adresler), resources, the network and the server. Health and Erişim come live (live.ts);
     the network card reads the WAN rate and the busiest applications' rates (GET /api/konsol/ag: each application's
     own bridge) every 5 s, only while this page is shown and the browser tab is visible. -->
<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../components/icons";
import AppIcon from "../components/AppIcon.vue";
import Card from "../components/ui/Card.vue";
import EmptyState from "../components/ui/EmptyState.vue";
import StatusPill from "../components/ui/StatusPill.vue";
import UsageBar from "../components/ui/UsageBar.vue";
import { apps, checkLevel, live, serverNow } from "../live";
import { problemList } from "../problems";
import { appState, warningText } from "../apps";
import { accessCounts, internetOpenings } from "../access";
import { accessRoute, systemRoute } from "../sections";
import { appRoute } from "../router";
import { readNetwork } from "../api/konsol";
import type { Ag } from "../api/sema";
import { UNKNOWN, bytes, percent, rate, shortVersion, since, uptime } from "../format";

// ---- Dikkat
const now = ref(serverNow());
let clockTimer: number | undefined;

const calm = computed(() => {
  const s = live.saglik;
  if (!s) return { known: false, sub: "Denetimlerin sonucu henüz gelmedi." };
  return { known: true, sub: `${s.checks.filter((c) => checkLevel(c.status) === "ok").length} denetim sorunsuz · son denetim ${since(s.read_at, now.value)}` };
});
const SEV_ICON: Record<"danger" | "warning" | "accent", "xcircle" | "alert" | "update"> = { danger: "xcircle", warning: "alert", accent: "update" };

// ---- applications: "Aç" opens the first address of one that runs (a new browser tab)
const ADDRESS_RE = /^https?:\/\/[^/\s]+/;
const cards = computed(() =>
  (apps.value ?? []).map((app) => {
    const fresh = app.guncelleme === "yeni";
    const notes = [app.uyari ? warningText(app.uyari) : "", fresh ? "yeni imaj var" : ""].filter(Boolean);
    const address = typeof app.adres === "string" && ADDRESS_RE.test(app.adres) ? app.adres : "";
    const host = address.replace(/^https?:\/\//, "").replace(/\/.*$/, "");
    return { app, state: appState(app), notes, address, host, open: Boolean(address) && (app.durum === "calisiyor" || app.durum === "kismen") };
  }),
);

// ---- the access summary
const access = computed(() => (live.erisim ? accessCounts(live.erisim.hizmetler) : null));
const openings = computed(() => internetOpenings(live.erisim?.hizmetler ?? []));
const wireguard = computed<{ value: string; label: string }>(() => {
  const w = live.erisim?.ozet.wireguard;
  if (!w) return { value: UNKNOWN, label: "WireGuard" };
  const open = w.durduruldu ? 0 : w.aglar.filter((a) => a.etkin).length;
  return open ? { value: String(open), label: "WireGuard ağı açık" } : { value: UNKNOWN, label: "WireGuard kapalı" };
});
const stat = (n: number | undefined) => (n === undefined ? UNKNOWN : String(n));

// ---- resources (each value checked: an event may carry only part of the object)
const num = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const cpu = computed(() => {
  const v = live.kaynaklar?.cpu;
  return num(v) ? v : null;
});
const cores = computed(() => (num(live.kaynaklar?.cores) ? `${live.kaynaklar.cores} çekirdek` : UNKNOWN));
const memory = computed(() => {
  const m = live.kaynaklar?.mem;
  if (!m || !num(m.total) || !num(m.used) || m.total <= 0) return null;
  return { text: `${bytes(m.used)} / ${bytes(m.total)}`, value: (100 * m.used) / m.total };
});
const disk = computed(() => {
  const d = live.kaynaklar?.disk;
  if (!d || !num(d.total) || !num(d.free) || d.total <= 0) return null;
  const used = Math.max(0, d.total - d.free);
  return { text: `${bytes(used)} / ${bytes(d.total)}`, value: (100 * used) / d.total };
});
const server = computed(() => {
  const k = live.kaynaklar;
  const text = (v: unknown) => (typeof v === "string" && v ? v : UNKNOWN);
  return { os: text(k?.os), uptime: uptime(k?.uptime), tailscale: text(k?.net?.tailscale), wan: text(k?.net?.wan), root: text(k?.root) };
});

// ---- network: every 5 s while this page is shown and the tab is visible
const net = ref<Ag | null>(null);
const netFailed = ref(false);
let netTimer: number | undefined;
let netBusy = false;

async function loadNetwork(): Promise<void> {
  if (netBusy || document.hidden) return;
  netBusy = true;
  try {
    net.value = await readNetwork();
    netFailed.value = false;
  } catch {
    netFailed.value = true;
  } finally {
    netBusy = false;
  }
}

function onVisibility(): void {
  if (!document.hidden) void loadNetwork();
}

const netLive = computed(() => !netFailed.value && net.value?.sampled_at != null);
/** The busiest applications under the WAN rate (the server sends a few, busiest first). */
const busiest = computed(() => (net.value?.uygulamalar ?? []).slice(0, 5));

// ---- server
const version = computed(() => live.kaynaklar?.surum || live.guncelleme?.kurulu_surum || shortVersion(live.kaynaklar?.version || live.guncelleme?.kurulu));
const update = computed(() => {
  const g = live.guncelleme;
  if (!g) return "";
  if (g.hata) return "denetlenemedi";
  return g.yeni ? "yeni sürüm var" : "güncel";
});

onMounted(() => {
  void loadNetwork();
  netTimer = window.setInterval(() => void loadNetwork(), 5000);
  clockTimer = window.setInterval(() => (now.value = serverNow()), 30000);
  document.addEventListener("visibilitychange", onVisibility);
});

onBeforeUnmount(() => {
  clearInterval(netTimer);
  clearInterval(clockTimer);
  document.removeEventListener("visibilitychange", onVisibility);
});

// "son denetim …" follows the server's clock as soon as it is known.
watch(() => live.offset, () => (now.value = serverNow()));
</script>

<template>
  <div class="page-body overview">
    <!-- Dikkat -->
    <section class="card attention" aria-labelledby="saglik-baslik" data-testid="health">
      <template v-if="problemList.length">
        <div class="card-head">
          <h2 id="saglik-baslik" class="card-title">Dikkat · {{ problemList.length }}</h2>
          <RouterLink class="btn btn-secondary btn-sm" :to="systemRoute('saglik')">Tüm denetimler</RouterLink>
        </div>
        <ul class="problems" aria-label="Dikkat isteyen konular">
          <li v-for="p in problemList" :key="p.key" class="problem" :class="'problem-' + p.tone" :data-kind="p.kind">
            <span class="sev" :class="'sev-' + p.tone" aria-hidden="true"><Icon :name="SEV_ICON[p.tone]" :size="18" /></span>
            <div class="problem-text">
              <strong>{{ p.title }}</strong>
              <span v-if="p.detail">{{ p.detail }}</span>
            </div>
            <RouterLink :to="p.to" class="btn btn-secondary btn-sm" data-eylem="duzelt">{{ p.label }}</RouterLink>
          </li>
        </ul>
      </template>
      <div v-else class="calm">
        <span class="sev" :class="calm.known ? 'sev-ok' : 'sev-neutral'" aria-hidden="true"><Icon :name="calm.known ? 'check' : 'unknown'" :size="20" /></span>
        <div class="calm-text">
          <h2 id="saglik-baslik" class="card-title">{{ calm.known ? "Her şey yolunda" : "Sağlık durumu okunuyor" }}</h2>
          <p class="meter-note" data-testid="health-sub">{{ calm.sub }}</p>
        </div>
        <RouterLink class="btn btn-secondary btn-sm" :to="systemRoute('saglik')">Tüm denetimler</RouterLink>
      </div>
    </section>

    <!-- applications -->
    <section class="card overview-apps" aria-labelledby="uyg-baslik" data-testid="overview-apps">
      <div class="card-head">
        <h2 id="uyg-baslik" class="card-title">Uygulamalar</h2>
        <RouterLink to="/uygulamalar" class="section-link" data-testid="all-apps">Tümü ({{ apps ? apps.length : UNKNOWN }})</RouterLink>
      </div>
      <div v-if="cards.length" class="app-grid">
        <article v-for="c in cards" :key="c.app.ad" class="app-card" :data-uygulama="c.app.ad">
          <div class="app-card-head">
            <AppIcon :app="c.app" />
            <div class="app-card-name">
              <RouterLink :to="appRoute(c.app.ad)" class="app-name">{{ c.app.ad }}</RouterLink>
              <StatusPill :tone="c.state.tone" :dot="c.app.durum === 'calisiyor'">{{ c.state.text }}</StatusPill>
            </div>
          </div>
          <p class="app-line">
            <span v-if="c.host" class="mono" data-testid="app-address">{{ c.host }}</span><span v-else class="muted">Dışarıya açık adresi yok</span><template
              v-for="n in c.notes" :key="n"> · <span :class="n === 'yeni imaj var' ? 'fresh' : 'warn-text'">{{ n }}</span></template>
          </p>
          <div class="app-card-actions">
            <a v-if="c.open" :href="c.address" class="btn btn-primary btn-sm" target="_blank" rel="noopener noreferrer" :aria-label="`${c.app.ad} uygulamasını aç`"
              data-eylem="ac">Aç<Icon name="open" :size="14" /></a>
            <RouterLink :to="appRoute(c.app.ad)" class="btn btn-secondary btn-sm" :aria-label="`${c.app.ad} ayrıntıları`">Ayrıntı</RouterLink>
          </div>
        </article>
      </div>
      <EmptyState
        v-else
        :title="apps ? 'Henüz uygulama yok.' : 'Uygulamalar henüz okunamadı'"
        :text="apps ? 'Uygulamalar bölümünden bir Compose ya da Kubernetes dosyasıyla eklenir.' : ''"
        icon="apps"
      />
    </section>

    <!-- the access summary -->
    <section class="card access-summary" aria-labelledby="erisim-ozet-baslik" data-testid="access-summary">
      <div class="card-head">
        <h2 id="erisim-ozet-baslik" class="card-title">Erişim özeti</h2>
        <RouterLink :to="accessRoute()" class="btn btn-secondary btn-sm">Erişim'e git</RouterLink>
      </div>
      <dl class="stats">
        <div class="stat" data-stat="tailscale"><dt>Tailscale adresi</dt><dd>{{ stat(access?.tailscale) }}</dd></div>
        <div class="stat" data-stat="internet"><dt>internet adı</dt><dd>{{ stat(access?.internet) }}</dd></div>
        <div class="stat" data-stat="ham-internet"><dt>internete açık ham port</dt><dd>{{ stat(access?.rawInternet) }}</dd></div>
        <div class="stat" data-stat="ham-tailscale"><dt>Tailscale'de ham port</dt><dd>{{ stat(access?.rawTailscale) }}</dd></div>
        <div class="stat" data-stat="wireguard"><dt>{{ wireguard.label }}</dt><dd>{{ wireguard.value }}</dd></div>
      </dl>
      <ul v-if="openings.length" class="access-chips" aria-label="İnternete açık olanlar">
        <li v-for="o in openings" :key="o.id">
          <RouterLink :to="accessRoute('adresler', o.id)" class="access-chip" :class="o.warn ? 'access-chip-warning' : 'access-chip-accent'" :data-satir="o.id">
            <span class="pill-dot" aria-hidden="true"></span>{{ o.text }}
          </RouterLink>
        </li>
      </ul>
      <p v-else-if="live.erisim" class="meter-note" data-testid="nothing-open">İnternete açık hiçbir şey yok.</p>
      <p v-else class="meter-note">Erişim henüz okunamadı.</p>
    </section>

    <div class="overview-grid">
      <!-- resources -->
      <Card title="Kaynaklar" :level="3" data-testid="resources">
        <div class="meter-row">
          <div class="meter-line"><span>İşlemci</span><strong data-testid="cpu">{{ cpu === null ? UNKNOWN : percent(cpu) }}</strong></div>
          <UsageBar :value="cpu" />
          <span class="meter-note">{{ cores }}</span>
        </div>
        <div class="meter-row">
          <div class="meter-line"><span>Bellek</span><strong data-testid="memory">{{ memory ? memory.text : UNKNOWN }}</strong></div>
          <UsageBar :value="memory ? memory.value : null" />
        </div>
        <div class="meter-row">
          <div class="meter-line">
            <span>Disk<template v-if="server.root !== UNKNOWN"> · {{ server.root }}</template></span>
            <strong data-testid="disk">{{ disk ? disk.text : UNKNOWN }}</strong>
          </div>
          <UsageBar :value="disk ? disk.value : null" />
        </div>
      </Card>

      <!-- network -->
      <Card title="Ağ" :level="3" data-testid="network">
        <template #actions>
          <StatusPill v-if="netLive" tone="ok" dot>Canlı</StatusPill>
        </template>
        <dl class="stats net-now">
          <div class="stat"><dt>indirme</dt><dd><span class="net-down" aria-hidden="true">↓</span><span data-testid="rx">{{ rate(net?.rx) }}</span></dd></div>
          <div class="stat"><dt>yükleme</dt><dd><span class="net-up" aria-hidden="true">↑</span><span data-testid="tx">{{ rate(net?.tx) }}</span></dd></div>
        </dl>
        <p v-if="netFailed" class="meter-note" data-testid="net-error">Ağ bilgisi okunamadı.</p>
        <ul v-else-if="busiest.length" class="net-apps" aria-label="En yoğun uygulamalar" data-testid="net-apps">
          <li v-for="a in busiest" :key="a.ad" :data-uygulama="a.ad">
            <RouterLink :to="appRoute(a.ad)" class="net-app-name">{{ a.ad }}</RouterLink>
            <span class="net-app-rate"><span class="net-down" aria-hidden="true">↓</span><span class="sr-only">İndirme </span>{{ rate(a.indirme) }}</span>
            <span class="net-app-rate"><span class="net-up" aria-hidden="true">↑</span><span class="sr-only">Yükleme </span>{{ rate(a.yukleme) }}</span>
          </li>
        </ul>
      </Card>

      <!-- server -->
      <Card title="Sunucu" :level="3" data-testid="server">
        <dl class="facts">
          <dt>Sistem</dt>
          <dd>{{ server.os }}</dd>
          <dt>Açık kalma</dt>
          <dd>{{ server.uptime }}</dd>
          <dt>Tailscale</dt>
          <dd class="mono">{{ server.tailscale }}</dd>
          <dt>İnternet</dt>
          <dd class="mono">{{ server.wan }}</dd>
          <dt>Obhut</dt>
          <dd data-testid="obhut">{{ version }}<template v-if="update"> · <span :class="{ fresh: update === 'yeni sürüm var' }">{{ update }}</span></template></dd>
        </dl>
      </Card>
    </div>
  </div>
</template>
