<!-- Dosyalar → Sunucu klasörleri (phase 4b, DD-267): the user area (/srv) as its owner account — browse,
     upload, download, new folder, rename, move, trash and the text editor (FolderBrowser), the rescue view
     for when Gezgin is down. The folder is in the address (?sekme=srv&yol=<relative path>). -->
<script setup lang="ts">
import FolderBrowser from "./FolderBrowser.vue";
</script>

<template>
  <div class="files-tab" data-testid="srv">
    <FolderBrowser tree="srv" />
  </div>
</template>
