<!-- The top bar's tools (DD-258): search (opens the command palette, ⌘K / Ctrl+K), the problem count that
     opens Uyarılar (problems.ts: the one list, each with its place), the running jobs (İşlemler) and the theme (A7: sistem → açık → koyu, its new choice announced). On a
     phone the bar is compact: icons, the count, the theme and, only while a job runs, the activity button. -->
<script setup lang="ts">
import { computed, ref } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "./icons";
import { runningJobs } from "../live";
import { problemSummary } from "../problems";
import { PROBLEMS } from "../router";
import { openSurface, ui } from "../ui";
import { nextTheme, setTheme, theme, themeText } from "../theme";

const props = defineProps<{ compact?: boolean }>();

const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
const shortcut = isMac ? "⌘K" : "Ctrl K";

const chip = computed(() => {
  const p = problemSummary.value;
  if (!p) return { level: "unknown", text: "Durum —", short: "—", label: "Sunucunun durumu bilinmiyor" };
  if (p.count === 0) return { level: "ok", text: "Her şey yolunda", short: "", label: "Her şey yolunda" };
  return { level: p.level, text: `${p.count} konu`, short: String(p.count), label: `${p.count} konu dikkat istiyor` };
});

const running = computed(() => runningJobs.value.length);
const activityLabel = computed(() => (running.value ? `İşlemler, ${running.value} çalışıyor` : "İşlemler"));

// The theme button names the current choice; a click takes the next one and says it.
const themeLabel = computed(() => `${themeText(theme.value)}; değiştir`);
const themeSaid = ref("");
function stepTheme(): void {
  setTheme(nextTheme(theme.value));
  themeSaid.value = themeText(theme.value);
}
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
      :to="PROBLEMS"
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
    <button type="button" class="icon-btn theme-btn" :data-tema="theme" :aria-label="themeLabel" :title="themeText(theme)" data-testid="theme" @click="stepTheme">
      <Icon name="theme" :size="18" />
    </button>
    <span class="sr-only" role="status">{{ themeSaid }}</span>
  </div>
</template>
