<!-- Dosyalar → Sistem dosyaları (phase 4b, DD-235, DD-267): the whole server as root, only on the tailnet and
     only from another Tailscale device (the backend checks both; Caddy routes /api/sistem/* on the tailnet
     site only). The same browser as Sunucu klasörleri, without trash or shares: a delete is permanent and
     needs the item's own name (or "onayla" for several), and the editor says it saves as root. When the
     backend refuses (the internet name, the server itself) the tab says why instead. -->
<script setup lang="ts">
import FolderBrowser from "./FolderBrowser.vue";
</script>

<template>
  <div class="files-tab" data-testid="sistem">
    <FolderBrowser tree="sistem" />
  </div>
</template>
