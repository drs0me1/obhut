<!-- The sidebar (DD-258): wordmark and server, the six sections with their counts, and the connection and
     version card. The phone shows the same content in the "Daha fazla" sheet. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "./icons";
import Wordmark from "./Wordmark.vue";
import { SECTIONS, type SectionId } from "../sections";
import { checkLevel, health, installedApps, live, type Level } from "../live";
import { UNKNOWN, fold, shortVersion } from "../format";

const emit = defineEmits<{ navigate: [to: SectionId] }>();

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
  const apps = installedApps.value;
  if (apps && apps.length) out.uygulamalar = { text: String(apps.length), level: "neutral", label: `${apps.length} kurulu uygulama` };
  const warnings = live.uyarilar;
  if (!live.erisimYok && warnings && warnings.length) {
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

// DD-260: the version people see ("1.0.0"); an older backend gives only the build number ("v2-242").
const version = computed(
  () => live.kaynaklar?.surum || live.guncelleme?.kurulu_surum || shortVersion(live.kaynaklar?.version || live.guncelleme?.kurulu),
);
const update = computed<{ text: string; fresh: boolean } | null>(() => {
  const g = live.guncelleme;
  if (!g) return null;
  if (g.hata) return { text: "denetlenemedi", fresh: false };
  return g.yeni === true ? { text: "yeni sürüm var", fresh: true } : { text: "güncel", fresh: false };
});
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
          <RouterLink :to="'/' + s.id" class="nav-item" :data-nav="s.id" @click="emit('navigate', s.id)">
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
          <RouterLink :to="'/' + s.id" class="nav-item" :data-nav="s.id" @click="emit('navigate', s.id)">
            <Icon :name="s.icon" />
            <span class="nav-label">{{ s.title }}</span>
          </RouterLink>
        </li>
      </ul>
    </nav>
    <div class="side-card" data-testid="side-card">
      <span class="side-ts" :class="'is-' + tailscale.level" :title="tailscale.detail || undefined" data-testid="tailscale">
        <span class="dot" aria-hidden="true"></span>{{ tailscale.text }}
      </span>
      <span data-testid="version">Obhut {{ version }}<template v-if="update"> · <span :class="{ 'side-fresh': update.fresh }">{{ update.text }}</span></template></span>
    </div>
  </div>
</template>
