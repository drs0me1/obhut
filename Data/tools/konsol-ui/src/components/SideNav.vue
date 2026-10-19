<!-- The sidebar (DD-258): wordmark and server, the seven sections with their counts and, at the foot, the resources
     card (the CPU, the memory, the disk of the user area, whose path Dosyalar → Depolama names; DD-287) and the server card (the Tailscale connection, the system, how long
     it has been up, its Tailscale and internet addresses, the Obhut version; DD-286). The phone shows the same
     content in the "Daha fazla" sheet. An open session on the
     internet channel adds "Çıkış yap" (DD-205: the tailnet address has no sign-in). -->
<script setup lang="ts">
import { computed, onMounted } from "vue";
import { RouterLink, useRoute } from "vue-router";
import { Icon } from "./icons";
import Wordmark from "./Wordmark.vue";
import UsageBar from "./ui/UsageBar.vue";
import { SECTIONS, type SectionId } from "../sections";
import { apps, checkLevel, health, live, type Level } from "../live";
import { UNKNOWN, bytes, fold, percent, shortVersion, uptime } from "../format";
import { canSignOut, leave, loadSession } from "../pages/sistem/session";

const emit = defineEmits<{ navigate: [to: SectionId] }>();

// The section's own page is the current page; a page below it (an application) is in the current section.
const route = useRoute();
const current = (id: SectionId) => (route.name === id ? "page" : route.meta.section === id ? "true" : undefined);

interface Badge {
  text: string;
  level: "neutral" | "warning" | "danger";
  label: string;
}

const main = SECTIONS.filter((s) => s.id !== "gelismis");
const advanced = SECTIONS.filter((s) => s.id === "gelismis");

const hostLine = computed(() => {
  const k = live.kaynaklar;
  if (!k?.host) return UNKNOWN;
  return k.domain ? `${k.host} · panel.${k.domain}` : k.host;
});

const badges = computed<Partial<Record<SectionId, Badge>>>(() => {
  const out: Partial<Record<SectionId, Badge>> = {};
  const list = apps.value;
  if (list && list.length) out.uygulamalar = { text: String(list.length), level: "neutral", label: `${list.length} kurulu uygulama` };
  const warnings = live.uyarilar;
  if (warnings && warnings.length) {
    out.erisim = {
      text: String(warnings.length),
      level: warnings.some((u) => u.seviye === "bad") ? "danger" : "warning",
      label: `${warnings.length} uyarı`,
    };
  }
  const h = health.value;
  if (h && h.danger + h.warning > 0) {
    const parts = [h.danger ? `${h.danger} hata` : "", h.warning ? `${h.warning} uyarı` : ""].filter(Boolean);
    out.sistem = { text: String(h.danger + h.warning), level: h.danger ? "danger" : "warning", label: parts.join(", ") };
  }
  return out;
});

const tailscale = computed<{ level: Level | "unknown"; text: string; detail: string }>(() => {
  const check = live.saglik?.checks.find((c) => c.id === "tailscale" || fold(c.name ?? "") === "tailscale");
  if (check) {
    const level = checkLevel(check.status);
    const text = level === "ok" ? "Tailscale bağlı" : level === "warning" ? "Tailscale: dikkat" : "Tailscale: sorun var";
    return { level, text, detail: check.detail ?? "" };
  }
  const k = live.kaynaklar;
  if (k) return k.net?.tailscale ? { level: "ok", text: "Tailscale bağlı", detail: k.net.tailscale } : { level: "warning", text: "Tailscale adresi yok", detail: "" };
  return { level: "unknown", text: `Tailscale ${UNKNOWN}`, detail: "" };
});

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

/** The server's facts under the connection: the system, how long it has been up, its addresses. */
const server = computed(() => {
  const k = live.kaynaklar;
  const text = (v: unknown) => (typeof v === "string" && v ? v : UNKNOWN);
  return { os: text(k?.os), uptime: uptime(k?.uptime), tailscale: text(k?.net?.tailscale), wan: text(k?.net?.wan) };
});

// DD-260: the version people see ("1.0.0"); the build number ("v2-242") when the server names none.
const version = computed(
  () => live.kaynaklar?.surum || live.guncelleme?.kurulu_surum || shortVersion(live.kaynaklar?.version || live.guncelleme?.kurulu),
);
const update = computed<{ text: string; fresh: boolean } | null>(() => {
  const g = live.guncelleme;
  if (!g) return null;
  if (g.hata) return { text: "denetlenemedi", fresh: false };
  return g.yeni === true ? { text: "yeni sürüm var", fresh: true } : { text: "güncel", fresh: false };
});

onMounted(() => void loadSession());
</script>

<template>
  <div class="side">
    <RouterLink to="/genel" class="brand" @click="emit('navigate', 'genel')">
      <Wordmark class="brand-mark" />
      <span class="brand-host" data-testid="host">{{ hostLine }}</span>
    </RouterLink>
    <nav class="side-nav" aria-label="Ana menü">
      <ul class="nav-list">
        <li v-for="s in main" :key="s.id">
          <RouterLink :to="'/' + s.id" class="nav-item" :data-nav="s.id" :aria-current="current(s.id)" @click="emit('navigate', s.id)">
            <Icon :name="s.icon" />
            <span class="nav-label">{{ s.title }}</span>
            <template v-if="badges[s.id]">
              <span class="badge" :class="'badge-' + badges[s.id]!.level" :data-badge="s.id" aria-hidden="true">{{ badges[s.id]!.text }}</span>
              <span class="sr-only">, {{ badges[s.id]!.label }}</span>
            </template>
          </RouterLink>
        </li>
      </ul>
      <div class="nav-divider" aria-hidden="true"></div>
      <ul class="nav-list">
        <li v-for="s in advanced" :key="s.id">
          <RouterLink :to="'/' + s.id" class="nav-item" :data-nav="s.id" :aria-current="current(s.id)" @click="emit('navigate', s.id)">
            <Icon :name="s.icon" />
            <span class="nav-label">{{ s.title }}</span>
          </RouterLink>
        </li>
      </ul>
    </nav>
    <div class="side-card side-meters" data-testid="side-resources">
      <span class="side-card-title">Kaynaklar</span>
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
        <div class="meter-line"><span>Disk</span><strong data-testid="disk">{{ disk ? disk.text : UNKNOWN }}</strong></div>
        <UsageBar :value="disk ? disk.value : null" />
      </div>
    </div>
    <div class="side-card" data-testid="side-card">
      <span class="side-ts" :class="'is-' + tailscale.level" :title="tailscale.detail || undefined" data-testid="tailscale">
        <span class="dot" aria-hidden="true"></span>{{ tailscale.text }}
      </span>
      <dl class="side-facts" data-testid="server">
        <dt>Sistem</dt>
        <dd>{{ server.os }}</dd>
        <dt>Açık kalma</dt>
        <dd>{{ server.uptime }}</dd>
        <dt>Tailscale</dt>
        <dd class="mono">{{ server.tailscale }}</dd>
        <dt>İnternet</dt>
        <dd class="mono">{{ server.wan }}</dd>
      </dl>
      <span data-testid="version">Obhut {{ version }}<template v-if="update"> · <span :class="{ 'side-fresh': update.fresh }">{{ update.text }}</span></template></span>
    </div>
    <button v-if="canSignOut" type="button" class="nav-item side-signout" data-testid="sign-out" @click="leave">
      <Icon name="power" />
      <span>Çıkış yap</span>
    </button>
  </div>
</template>
