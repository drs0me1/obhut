<!-- Theme choice (Sistem / Açık / Koyu) as a radio group: one tab stop, arrow keys move and choose. -->
<script setup lang="ts">
import { nextTick, ref } from "vue";
import { THEMES, setTheme, theme, type ThemeChoice } from "../theme";

const buttons = ref<HTMLButtonElement[]>([]);

function choose(id: ThemeChoice): void {
  setTheme(id);
}

function onKeydown(event: KeyboardEvent, index: number): void {
  const step = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 0;
  if (!step) return;
  event.preventDefault();
  const next = THEMES[(index + step + THEMES.length) % THEMES.length];
  if (!next) return;
  choose(next.id);
  void nextTick(() => buttons.value.find((b) => b.dataset.tema === next.id)?.focus());
}
</script>

<template>
  <div class="theme-field">
    <span id="tema-etiket" class="field-label">Tema</span>
    <div class="segmented" role="radiogroup" aria-labelledby="tema-etiket">
      <button
        v-for="(t, i) in THEMES"
        :key="t.id"
        ref="buttons"
        type="button"
        role="radio"
        class="segment"
        :data-tema="t.id"
        :aria-checked="theme === t.id"
        :tabindex="theme === t.id ? 0 : -1"
        @click="choose(t.id)"
        @keydown="onKeydown($event, i)"
      >
        {{ t.label }}
      </button>
    </div>
    <p class="field-help">Sistem, cihazınızın açık ya da koyu ayarını izler. Seçim yalnız bu tarayıcıda saklanır.</p>
  </div>
</template>
