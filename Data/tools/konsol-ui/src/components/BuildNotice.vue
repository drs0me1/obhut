<!-- The files this page runs were replaced on the server (build.ts, DD-280). With nothing unsaved and no dialog
     open the page says so and reloads itself a moment later; otherwise it waits for "Şimdi yenile", since a
     reload drops what was entered. -->
<script setup lang="ts">
import { ref, watch } from "vue";
import { Icon } from "./icons";
import { newBuild } from "../build";
import { hasDrafts } from "../leave";
import { live } from "../live";
import { shortVersion } from "../format";
import { ui } from "../ui";

const RELOAD_MS = 2000;
const held = ref(false);

watch(newBuild, (on) => {
  if (!on) return;
  if (hasDrafts() || ui.open !== null) held.value = true;
  else window.setTimeout(() => location.reload(), RELOAD_MS);
});

function reload(): void {
  location.reload();
}
</script>

<template>
  <div v-if="newBuild" class="notice build-notice" :class="{ 'notice-warning': held }" role="status" data-testid="build-notice">
    <Icon name="update" class="notice-icon" />
    <span class="build-notice-text">
      Konsol güncellendi (yapı {{ shortVersion(live.kaynaklar?.version) }}).
      {{ held ? "Yeni arayüz sayfa yenilenince açılır; yenileyince girdikleriniz silinir." : "Sayfa yenileniyor…" }}
    </span>
    <button v-if="held" type="button" class="btn btn-secondary btn-sm" data-eylem="yenile" @click="reload">Şimdi yenile</button>
  </div>
</template>
