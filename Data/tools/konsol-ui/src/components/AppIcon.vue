<!-- An application's tile: its package icon (konsol.json "simge") or the kind's, on one of four colours that
     stays the same for the same application. Decorative: the name is always written beside it. -->
<script setup lang="ts">
import { computed } from "vue";
import { Icon } from "./icons";
import { appIcon, appTile } from "../apps";
import type { Uygulama } from "../api/sema";

const props = withDefaults(defineProps<{ app: Pick<Uygulama, "id" | "simge" | "tur">; size?: "sm" | "md" | "lg" }>(), { size: "md" });
const icon = computed(() => appIcon(props.app));
const tile = computed(() => appTile(props.app));
const px = computed(() => (props.size === "lg" ? 30 : props.size === "sm" ? 20 : 22));
</script>

<template>
  <span class="app-icon" :class="['app-icon-' + size, 'tile-' + tile]" aria-hidden="true"><Icon :name="icon" :size="px" /></span>
</template>
