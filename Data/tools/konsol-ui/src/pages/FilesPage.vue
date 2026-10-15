<!-- Dosyalar (DD-258, phase 4b, DD-267): the user area's storage and the folders each application uses,
     a lean view of the server folders (/srv), the trash, folder shares and, on the tailnet only, the whole
     server as root ("Sistem dosyaları"). Gezgin is the file manager for everything else. Tabs in the
     address (?sekme=); a folder browser's own values (yol=, ara=, dosya=) belong to its tab and are left
     behind when another tab is chosen, unless the same change set them (a link into a folder). -->
<script setup lang="ts">
import { computed } from "vue";
import { onBeforeRouteUpdate } from "vue-router";
import Tabs from "../components/ui/Tabs.vue";
import StorageTab from "./dosyalar/StorageTab.vue";
import FolderTab from "./dosyalar/FolderTab.vue";
import TrashTab from "./dosyalar/TrashTab.vue";
import SharesTab from "./dosyalar/SharesTab.vue";
import SystemFilesTab from "./dosyalar/SystemFilesTab.vue";
import { FILES_TABS } from "../sections";

// Sistem dosyaları answers only on the tailnet (DD-235); the internet name never shows the tab.
const tailnet = location.protocol === "http:";
const TABS = computed(() => FILES_TABS.filter((t) => t.id !== "sistem" || tailnet).map((t) => ({ id: t.id, label: t.label })));

// Choosing another tab drops the browser's values the change did not set itself, before the new tab opens
// (Sunucu klasörleri' folder never opens in Sistem dosyaları).
const BROWSER_KEYS = ["yol", "ara", "dosya"] as const;
onBeforeRouteUpdate((to, from) => {
  if (to.path !== from.path || to.query.sekme === from.query.sekme) return true;
  const stale = BROWSER_KEYS.filter((k) => to.query[k] !== undefined && to.query[k] === from.query[k]);
  if (!stale.length) return true;
  const query = { ...to.query };
  for (const k of stale) delete query[k];
  return { path: to.path, query, hash: to.hash };
});
</script>

<template>
  <div class="page-body files-page">
    <Tabs :tabs="TABS" label="Dosyalar bölümleri" param="sekme">
      <template #default="{ active }">
        <StorageTab v-if="active === 'depolama'" />
        <FolderTab v-else-if="active === 'srv'" />
        <TrashTab v-else-if="active === 'cop'" />
        <SharesTab v-else-if="active === 'paylasimlar'" />
        <SystemFilesTab v-else-if="active === 'sistem'" />
      </template>
    </Tabs>
  </div>
</template>
