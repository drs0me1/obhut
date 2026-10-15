<!-- Genel Bakış (DD-258, phase 2): health first — what needs attention, each with its one fix, or a calm
     "Her şey yolunda" — then the applications, resources, network and the server. Health and Erişim's
     warnings come live (live.ts); repair is asked of GET /api/konsol/onarim (started only on the tailnet,
     DD-239); the network card reads GET /api/konsol/ag every 5 s, only while this page is shown and the
     browser tab is visible. -->
<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../components/icons";
import AppIcon from "../components/AppIcon.vue";
import Card from "../components/ui/Card.vue";
import EmptyState from "../components/ui/EmptyState.vue";
import Modal from "../components/ui/Modal.vue";
import StatusPill from "../components/ui/StatusPill.vue";
import UsageBar from "../components/ui/UsageBar.vue";
import type { Tone } from "../components/ui/types";
import { apps, checkLevel, live, serverNow } from "../live";
import { accessLine, appState, openTarget } from "../apps";
import { fixRoute } from "../access";
import { appRoute } from "../router";
import { readNetwork, readRepair, startRepair } from "../api/konsol";
import type { Ag, Onarim } from "../api/sema";
import { UNKNOWN, bytes, percent, rate, shortVersion, since, uptime } from "../format";

// ---- health and Erişim's warnings
interface Problem {
  key: string;
  kind: "saglik" | "erisim";
  tone: Extract<Tone, "warning" | "danger">;
  title: string;
  detail: string;
  /** Where an Erişim warning is fixed (its `duzelt`). */
  fix: string;
}

const serviceNames = computed(() => {
  const names = new Map<string, string>([["panel", "Konsol"], ["tailscale", "Tailscale"], ["paylasim", "Paylaşımlar"]]);
  for (const app of live.uygulamalar?.items ?? []) names.set(app.id, app.ad);
  return names;
});

const problemList = computed<Problem[]>(() => {
  const out: Problem[] = [];
  for (const check of live.saglik?.checks ?? []) {
    const level = checkLevel(check.status);
    if (level === "ok") continue;
    out.push({ key: "saglik:" + check.id, kind: "saglik", tone: level, title: check.name || check.id, detail: check.detail, fix: "" });
  }
  (live.uyarilar ?? []).forEach((u, i) => {
    const service = serviceNames.value.get(u.hizmet);
    out.push({ key: `erisim:${i}`, kind: "erisim", tone: u.seviye === "bad" ? "danger" : "warning", title: u.metin, detail: service ? `Erişim · ${service}` : "Erişim",
      fix: fixRoute(u.duzelt ?? null) });
  });
  // The most serious first; otherwise in the server's order.
  return out.map((p, i) => [p, i] as const).sort((a, b) => (a[0].tone === b[0].tone ? a[1] - b[1] : a[0].tone === "danger" ? -1 : 1)).map(([p]) => p);
});

const now = ref(serverNow());
let clockTimer: number | undefined;

const healthHead = computed(() => {
  const s = live.saglik;
  const count = problemList.value.length;
  const checks = s?.checks.length ?? 0;
  const okCount = s ? s.checks.filter((c) => checkLevel(c.status) === "ok").length : 0;
  const when = s ? `son denetim ${since(s.read_at, now.value)}` : "";
  if (count > 0) {
    const tone: Tone = problemList.value.some((p) => p.tone === "danger") ? "danger" : "warning";
    return { tone, title: `${count} konu dikkat istiyor`, sub: s ? `Diğer ${okCount} denetim sorunsuz · ${when}` : "Sağlık denetimleri henüz okunamadı." };
  }
  if (!s) return { tone: "neutral" as Tone, title: "Sağlık durumu okunuyor", sub: "Denetimlerin sonucu henüz gelmedi." };
  return { tone: "ok" as Tone, title: "Her şey yolunda", sub: `${checks} denetim sorunsuz · ${when}` };
});

// ---- repair (DD-239)
const repair = ref<Onarim | null>(null);
const repairFailed = ref(false);
const repairAsk = ref(false);
const repairBusy = ref(false);
const repairError = ref("");
const repairStarted = ref(false);

async function loadRepair(): Promise<void> {
  try {
    repair.value = await readRepair();
    repairFailed.value = false;
  } catch {
    repairFailed.value = true;
  }
}

const repairLock = computed(() => {
  const r = repair.value;
  if (!r) return repairFailed.value ? "Onarım durumu okunamadı." : "";
  if (!r.baslatilabilir) return "Onarım yalnız Tailscale adresinden başlatılır.";
  if (!r.kurulu) return "Onarım aracı kurulu değil; kurulumu bir kez yeniden çalıştırın.";
  return "";
});
const repairRunning = computed(() => repair.value?.calisiyor === true);
const repairDisabled = computed(() => !repair.value || Boolean(repairLock.value) || repairRunning.value || repairBusy.value);

function askRepair(): void {
  repairError.value = "";
  repairAsk.value = true;
}

async function confirmRepair(): Promise<void> {
  if (repairBusy.value) return;
  repairBusy.value = true;
  repairError.value = "";
  try {
    await startRepair();
    repairAsk.value = false;
    repairStarted.value = true;
    if (repair.value) repair.value = { ...repair.value, calisiyor: true };
    void loadRepair();
  } catch (err) {
    repairError.value = err instanceof Error ? err.message : String(err);
  } finally {
    repairBusy.value = false;
  }
}

// A repair that ends (the activity drawer's "onarim" job) changes the report; health is re-read by live.ts.
const repairJobs = computed(() => (live.islemler ?? []).filter((j) => j.tur === "onarim").map((j) => j.durum).join(","));
watch(repairJobs, (jobs) => {
  if (jobs && !jobs.includes("calisiyor")) repairStarted.value = false;
  void loadRepair();
});

// ---- applications
const cards = computed(() =>
  (apps.value ?? []).map((app) => {
    const open = openTarget(app);
    return {
      app,
      state: appState(app),
      line: accessLine(app),
      open: open && {
        ...open,
        label: open.external ? `${app.ad} uygulamasını yeni sekmede aç` : `${app.ad} sayfasını aç`,
      },
    };
  }),
);

// ---- resources (each value checked: an event may carry only part of the object)
const num = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const cpu = computed(() => {
  const list = live.kaynaklar?.cpu;
  const last = Array.isArray(list) && list.length ? list[list.length - 1] : undefined;
  return num(last) ? last : null;
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

// ---- server
const version = computed(() => live.kaynaklar?.surum || live.guncelleme?.kurulu_surum || shortVersion(live.kaynaklar?.version || live.guncelleme?.kurulu));
const update = computed(() => {
  const g = live.guncelleme;
  if (!g) return "";
  if (g.hata) return "denetlenemedi";
  return g.yeni ? "yeni sürüm var" : "güncel";
});

onMounted(() => {
  void loadRepair();
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
    <!-- health -->
    <section class="card health" :class="'health-' + healthHead.tone" aria-labelledby="saglik-baslik" data-testid="health">
      <svg class="health-art" viewBox="0 0 600 160" preserveAspectRatio="none" aria-hidden="true" focusable="false">
        <path d="M0 160 110 78 200 122 320 34 440 112 520 66 600 118V160Z" />
      </svg>
      <div class="health-head">
        <div class="health-summary">
          <span class="health-icon" aria-hidden="true">
            <Icon :name="healthHead.tone === 'ok' ? 'check' : healthHead.tone === 'neutral' ? 'unknown' : 'alert'" :size="24" />
          </span>
          <div>
            <h2 id="saglik-baslik" class="health-title">{{ healthHead.title }}</h2>
            <p class="health-sub" data-testid="health-sub">{{ healthHead.sub }}</p>
          </div>
        </div>
        <RouterLink class="btn btn-secondary" to="/sistem?sekme=saglik">Tüm denetimler</RouterLink>
      </div>
      <ul v-if="problemList.length" class="problems" aria-label="Dikkat isteyen konular">
        <li v-for="p in problemList" :key="p.key" class="problem" :class="'problem-' + p.tone" :data-kind="p.kind">
          <Icon :name="p.tone === 'danger' ? 'xcircle' : 'alert'" :size="22" class="problem-icon" />
          <div class="problem-text">
            <strong>{{ p.title }}</strong>
            <span v-if="p.detail">{{ p.detail }}</span>
          </div>
          <button
            v-if="p.kind === 'saglik'"
            type="button"
            class="btn btn-secondary"
            :disabled="repairDisabled"
            :aria-describedby="repairLock ? 'onarim-not' : undefined"
            @click="askRepair"
          >
            {{ repairRunning ? "Onarım sürüyor…" : "Denetle ve onar" }}
          </button>
          <RouterLink v-else :to="p.fix" class="btn btn-primary" data-eylem="duzelt">Düzelt</RouterLink>
        </li>
      </ul>
      <p v-if="repairLock && problemList.some((p) => p.kind === 'saglik')" id="onarim-not" class="health-note" data-testid="repair-lock">{{ repairLock }}</p>
      <p class="sr-only" role="status">{{ repairStarted ? "Denetim ve onarım başladı; ilerlemesi İşlemler'de görünür." : "" }}</p>
      <p v-if="repairStarted" class="health-note" aria-hidden="true">Denetim ve onarım başladı; ilerlemesi İşlemler'de görünür.</p>
    </section>

    <!-- applications -->
    <section class="overview-apps" aria-labelledby="uyg-baslik">
      <div class="section-head">
        <h2 id="uyg-baslik" class="section-title">Uygulamalar</h2>
        <RouterLink to="/uygulamalar" class="section-link" data-testid="all-apps">Tümü ({{ apps ? apps.length : UNKNOWN }})</RouterLink>
      </div>
      <div v-if="cards.length" class="app-grid">
        <article v-for="c in cards" :key="c.app.id" class="app-card" :data-uygulama="c.app.id">
          <div class="app-card-head">
            <AppIcon :app="c.app" />
            <div class="app-card-name">
              <RouterLink :to="appRoute(c.app.id)" class="app-name">{{ c.app.ad }}</RouterLink>
              <StatusPill :tone="c.state.tone" :dot="c.app.durum === 'calisiyor'">{{ c.state.text }}</StatusPill>
            </div>
          </div>
          <p class="app-line">{{ c.line }}<template v-if="c.app.guncelleme === 'yeni'"> · <span class="fresh">yeni sürüm var</span></template></p>
          <div class="app-card-actions">
            <a
              v-if="c.open"
              class="btn btn-primary btn-sm"
              :href="c.open.href"
              :target="c.open.external ? '_blank' : undefined"
              :rel="c.open.external ? 'noopener noreferrer' : undefined"
              :aria-label="c.open.label"
              data-eylem="ac"
            >
              Aç<Icon v-if="c.open.external" name="open" :size="16" />
            </a>
            <RouterLink :to="appRoute(c.app.id)" class="btn btn-secondary btn-sm" :aria-label="`${c.app.ad} ayrıntıları`">Ayrıntı</RouterLink>
          </div>
        </article>
      </div>
      <Card v-else as="div">
        <EmptyState
          :title="apps ? 'Henüz uygulama yok' : 'Uygulamalar henüz okunamadı'"
          :text="apps ? 'App Store\'dan bir uygulama kurabilir ya da bir imajdan konteyner çalıştırabilirsiniz.' : ''"
        >
          <RouterLink v-if="apps" to="/uygulamalar" class="btn btn-secondary">Uygulama ekle</RouterLink>
        </EmptyState>
      </Card>
    </section>

    <div class="overview-grid">
      <!-- resources -->
      <Card title="Kaynaklar" data-testid="resources">
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
      <Card title="Ağ" data-testid="network">
        <template #actions>
          <StatusPill v-if="netLive" tone="ok">Canlı</StatusPill>
        </template>
        <div class="net-now">
          <span class="net-rate"><span class="net-down" aria-hidden="true">↓</span><span class="sr-only">İndirme </span><span data-testid="rx">{{ rate(net?.rx) }}</span></span>
          <span class="net-rate"><span class="net-up" aria-hidden="true">↑</span><span class="sr-only">Gönderme </span><span data-testid="tx">{{ rate(net?.tx) }}</span></span>
        </div>
        <div class="net-sep" aria-hidden="true"></div>
        <div class="net-apps">
          <span class="meter-note">Toplam aktarım</span>
          <ul v-if="net && net.apps.length" class="net-list" aria-label="Uygulamaların toplam aktarımı">
            <li v-for="a in net.apps" :key="a.id" :data-uygulama="a.id">
              <span>{{ a.name }}</span>
              <span>↓ {{ bytes(a.down) }} · ↑ {{ bytes(a.up) }}</span>
            </li>
          </ul>
          <p v-else class="meter-note">{{ net ? "Trafiğini bildiren uygulama yok." : netFailed ? "Ağ bilgisi okunamadı." : UNKNOWN }}</p>
        </div>
      </Card>

      <!-- server -->
      <Card title="Sunucu" data-testid="server">
        <dl class="facts">
          <dt>Sistem</dt>
          <dd>{{ server.os }}</dd>
          <dt>Açık kalma</dt>
          <dd>{{ server.uptime }}</dd>
          <dt>Tailscale</dt>
          <dd class="mono">{{ server.tailscale }}</dd>
          <dt>İnternet adresi</dt>
          <dd class="mono">{{ server.wan }}</dd>
          <dt>Obhut</dt>
          <dd data-testid="obhut">{{ version }}<template v-if="update"> · <span :class="{ fresh: update === 'yeni sürüm var' }">{{ update }}</span></template></dd>
        </dl>
      </Card>
    </div>

    <Modal :open="repairAsk" title="Denetim ve onarım başlasın mı?" @close="repairAsk = false">
      <ul class="modal-list">
        <li><Icon name="shield" :size="18" /><span>Güvenlik duvarı, Tailscale ve adresi, servisler, DNS ve Konsol denetlenir.</span></li>
        <li><Icon name="refresh" :size="18" /><span>Bozuk olanlar yeniden başlatılır ya da yeniden kurulur; yapılandırma dosyaları değişmez.</span></li>
        <li><Icon name="alert" :size="18" /><span>Caddy ya da Konsol yeniden başlarsa sayfa birkaç saniye yanıt vermeyebilir.</span></li>
      </ul>
      <p v-if="repairError" class="form-error" role="alert">{{ repairError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" data-autofocus @click="repairAsk = false">Vazgeç</button>
        <button type="button" class="btn btn-primary" :disabled="repairBusy" @click="confirmRepair">{{ repairBusy ? "Başlatılıyor…" : "Onar" }}</button>
      </template>
    </Modal>
  </div>
</template>
