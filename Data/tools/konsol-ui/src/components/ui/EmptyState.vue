<!-- The empty state (DD-258 goal 5): what is missing, why, and what to do next (the default slot). -->
<script setup lang="ts">
import { Icon, type IconName } from "../icons";

withDefaults(defineProps<{ title: string; text?: string; icon?: IconName }>(), { text: "", icon: "box" });
</script>

<template>
  <div class="empty-state">
    <span class="empty-icon" aria-hidden="true"><Icon :name="icon" :size="22" /></span>
    <p class="empty-title">{{ title }}</p>
    <p v-if="text" class="empty-text">{{ text }}</p>
    <div v-if="$slots.default" class="empty-actions"><slot /></div>
  </div>
</template>
