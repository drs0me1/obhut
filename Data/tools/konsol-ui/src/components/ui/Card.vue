<!-- The card (DD-258 goal 5): a calm surface with an optional heading and actions beside it. With a title
     the card is a labelled region; without one it is a plain container. -->
<script setup lang="ts">
import { useId } from "vue";

withDefaults(defineProps<{ title?: string; as?: "section" | "article" | "div"; level?: 2 | 3 }>(), {
  title: undefined,
  as: "section",
  level: 2,
});
const titleId = useId();
</script>

<template>
  <component :is="as" class="card" :aria-labelledby="title ? titleId : undefined">
    <div v-if="title || $slots.actions" class="card-head">
      <component :is="'h' + level" v-if="title" :id="titleId" class="card-title">{{ title }}</component>
      <div v-if="$slots.actions" class="card-actions"><slot name="actions" /></div>
    </div>
    <slot />
  </component>
</template>
