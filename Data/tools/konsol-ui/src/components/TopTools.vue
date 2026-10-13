<!-- The top bar's tools (DD-258): search (opens the command palette, ⌘K / Ctrl+K), the problem count that
     leads to Sistem, and the running jobs. On a phone the bar is compact: icons, the count and, only while a
     job runs, the activity button. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "./icons";
import { problems, runningJobs } from "../live";
import { openSurface, ui } from "../ui";

const props = defineProps<{ compact?: boolean }>();

const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
const shortcut = isMac ? "⌘K" : "Ctrl K";

const chip = computed(() => {
  const p = problems.value;
  if (!p) return { level: "unknown", text: "Durum —", short: "—", label: "Sunucunun durumu bilinmiyor" };
  if (p.count === 0) return { level: "ok", text: "Her şey yolunda", short: "", label: "Her şey yolunda" };
  return { level: p.level, text: `${p.count} konu`, short: String(p.count), label: `${p.count} konu dikkat istiyor` };
});

const running = computed(() => runningJobs.value.length);
const activityLabel = computed(() => (running.value ? `İşlemler, ${running.value} çalışıyor` : "İşlemler"));
</script>

<template>
  <div class="tools" :class="{ 'tools-compact': props.compact }">
    <button
      v-if="!props.compact"
      type="button"
      class="search-field"
      aria-label="Ara ya da komut yaz"
      aria-haspopup="dialog"
      :aria-expanded="ui.open === 'palette'"
      aria-keyshortcuts="Meta+K Control+K"
      @click="openSurface('palette')"
    >
      <Icon name="search" :size="18" />
      <span class="search-text">Ara ya da komut yaz…</span>
      <kbd>{{ shortcut }}</kbd>
    </button>
    <button
      v-else
      type="button"
      class="icon-btn"
      aria-label="Ara"
      aria-haspopup="dialog"
      :aria-expanded="ui.open === 'palette'"
      @click="openSurface('palette')"
    >
      <Icon name="search" />
    </button>
    <RouterLink
      to="/sistem"
      class="chip"
      :class="'chip-' + chip.level"
      :aria-label="props.compact ? chip.label : undefined"
      data-testid="problems"
    >
      <Icon :name="chip.level === 'ok' ? 'check' : chip.level === 'unknown' ? 'unknown' : 'alert'" :size="18" />
      <span v-if="!props.compact" class="chip-text">{{ chip.text }}</span>
      <span v-else-if="chip.short" class="chip-text">{{ chip.short }}</span>
    </RouterLink>
    <button
      v-if="!props.compact || running"
      type="button"
      :class="props.compact ? 'icon-btn activity-btn' : 'tool-btn activity-btn'"
      aria-haspopup="dialog"
      :aria-expanded="ui.open === 'drawer'"
      :aria-label="props.compact || running ? activityLabel : undefined"
      @click="openSurface('drawer')"
    >
      <Icon name="pulse" :size="18" />
      <span v-if="!props.compact">İşlemler</span>
      <span v-if="running" class="count" aria-hidden="true">{{ running }}</span>
    </button>
  </div>
</template>
