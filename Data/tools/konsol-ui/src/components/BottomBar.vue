<!-- The phone's bottom bar (DD-258): four sections and "Daha fazla", which opens the sidebar as a sheet. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink, useRoute } from "vue-router";
import { Icon } from "./icons";
import { SECTIONS } from "../sections";
import { openSurface, ui } from "../ui";

const route = useRoute();
const shown = SECTIONS.filter((s) => s.id === "genel" || s.id === "uygulamalar" || s.id === "erisim" || s.id === "dosyalar");
const moreActive = computed(() => route.name === "sistem" || route.name === "gelismis");
</script>

<template>
  <nav class="bottom-bar" aria-label="Alt menü">
    <RouterLink v-for="s in shown" :key="s.id" :to="'/' + s.id" class="bb-item" :data-nav="s.id">
      <Icon :name="s.icon" :size="22" />
      <span>{{ s.short }}</span>
    </RouterLink>
    <button
      type="button"
      class="bb-item"
      :class="{ 'is-active': moreActive }"
      aria-haspopup="dialog"
      :aria-expanded="ui.open === 'sheet'"
      @click="openSurface('sheet')"
    >
      <Icon name="more" :size="22" />
      <span>Daha fazla</span>
    </button>
  </nav>
</template>
