<!-- The status pill (DD-258 goal 5): a short state in its colour, with an optional dot for a live state
     ("● Çalışıyor"). The colour never carries the meaning alone; the text does. -->
<script setup lang="ts">
import type { Tone } from "./types";

withDefaults(defineProps<{ tone?: Tone; dot?: boolean }>(), { tone: "neutral", dot: false });
</script>

<template>
  <span class="pill" :class="'pill-' + tone"><span v-if="dot" class="pill-dot" aria-hidden="true"></span><slot /></span>
</template>
