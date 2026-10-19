<!-- A summary card: one fixed template, so the cards of a row line up (Erişim → Genel). The title with its state
     beside it; at most three one-line rows, a label and its value (a longer list shows two and how many more; a long
     value is shortened, whole on hover), or one line saying there is nothing; and at its foot a link to the tab
     where the details are and change (or, `external`, to a page elsewhere, in a new tab). Cards of a row are as
     tall as the tallest; the link keeps to the foot. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import Card from "./Card.vue";
import StatusPill from "./StatusPill.vue";
import { Icon } from "../icons";
import type { Tone } from "./types";

export interface SummaryRow {
  label: string;
  value: string;
  mono?: boolean;
  tone?: "warn" | "muted";
  /** What the row means in full, on hover (the value when absent). */
  hint?: string;
}

const props = defineProps<{
  title: string;
  state: { text: string; tone: Tone; dot?: boolean };
  rows: readonly SummaryRow[];
  empty: string;
  link: { to: string; text: string; external?: boolean };
}>();

const MAX = 3;
const shown = computed<SummaryRow[]>(() =>
  props.rows.length <= MAX ? [...props.rows] : [...props.rows.slice(0, MAX - 1), { label: "", value: `${props.rows.length - MAX + 1} tane daha`, tone: "muted" }],
);
</script>

<template>
  <Card :title="title" :level="3" class="summary-card">
    <template #actions><StatusPill :tone="state.tone" :dot="state.dot">{{ state.text }}</StatusPill></template>
    <dl v-if="shown.length" class="summary-rows">
      <template v-for="(r, i) in shown" :key="i">
        <dt :class="{ 'warn-text': r.tone === 'warn' }">{{ r.label }}</dt>
        <dd :class="{ mono: r.mono, 'warn-text': r.tone === 'warn', muted: r.tone === 'muted' }" :title="r.hint ?? r.value">{{ r.value }}</dd>
      </template>
    </dl>
    <p v-else class="meter-note summary-empty">{{ empty }}</p>
    <a v-if="link.external" :href="link.to" target="_blank" rel="noopener noreferrer" class="summary-link">{{ link.text }}<Icon name="open" :size="14" /></a>
    <RouterLink v-else :to="link.to" class="summary-link">{{ link.text }}<Icon name="chevron" :size="14" /></RouterLink>
  </Card>
</template>
