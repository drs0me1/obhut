<!-- A usage bar beside a value that is already written out (decorative, hidden from screen readers). Drawn
     in SVG with a width attribute: the console's CSP allows no style attribute. -->
<script setup lang="ts">
import { computed } from "vue";

const props = defineProps<{ value: number | null }>();
const width = computed(() => (props.value === null || !Number.isFinite(props.value) ? null : `${Math.min(100, Math.max(0, props.value))}%`));
</script>

<template>
  <svg class="usage" width="100%" height="6" aria-hidden="true" focusable="false">
    <rect class="usage-track" width="100%" height="6" rx="3" />
    <rect v-if="width" class="usage-fill" :width="width" height="6" rx="3" />
  </svg>
</template>
