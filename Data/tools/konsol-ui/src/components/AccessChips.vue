<!-- How an application is reached, as chips for its Tailscale and internet cells (Erişim's read model):
     open, partly open, closed or failing; a warning such as "Şifresiz HTTP" shows in the warning colour.
     A cell that does not apply has no chip; with none, "—". -->
<script setup lang="ts">
import { computed } from "vue";
import { accessChips } from "../apps";
import { UNKNOWN } from "../format";
import type { Uygulama } from "../api/sema";

const props = defineProps<{ app: Pick<Uygulama, "tailscale" | "internet"> }>();
const chips = computed(() => accessChips(props.app));
</script>

<template>
  <ul v-if="chips.length" class="access-chips">
    <li v-for="c in chips" :key="c.scope" class="access-chip" :class="'chip-tone-' + c.tone" :data-erisim="c.scope" :title="c.detail || undefined">
      <span class="access-dot" aria-hidden="true"></span><span class="access-text">{{ c.text }}</span><span v-if="c.detail" class="sr-only">: {{ c.detail }}</span>
    </li>
  </ul>
  <span v-else class="muted">{{ UNKNOWN }}</span>
</template>
