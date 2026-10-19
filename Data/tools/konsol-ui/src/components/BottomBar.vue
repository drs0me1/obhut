<!-- The phone's bottom bar (DD-258): four sections and "Daha fazla", which opens the sidebar as a sheet. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink, useRoute } from "vue-router";
import { Icon } from "./icons";
import { SECTIONS, type SectionId } from "../sections";
import { openSurface, ui } from "../ui";

const route = useRoute();
const shown = SECTIONS.filter((s) => s.id === "genel" || s.id === "uygulamalar" || s.id === "erisim" || s.id === "dosyalar");
const moreActive = computed(() => route.meta.section === "podman" || route.meta.section === "sistem" || route.meta.section === "gelismis");
// The section's own page is the current page; a page below it (an application) is in the current section.
const current = (id: SectionId) => (route.name === id ? "page" : route.meta.section === id ? "true" : undefined);
</script>

<template>
  <nav class="bottom-bar" aria-label="Alt menü">
    <RouterLink v-for="s in shown" :key="s.id" :to="'/' + s.id" class="bb-item" :data-nav="s.id" :aria-current="current(s.id)">
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
