<!-- The upload queue of one tree (uploads.ts): every waiting, running, skipped or failed upload with its
     target folder, size, progress and state; a waiting or running one is cancelled, a skipped or failed
     one's line removed. Uploads that finished are gone from it (the folder view says so). -->
<script setup lang="ts">
import { computed } from "vue";
import { Icon } from "../../components/icons";
import UsageBar from "../../components/ui/UsageBar.vue";
import type { Tree } from "../../api/dosyalar";
import { bytes } from "../../format";
import { fullPath } from "./files";
import { cancelUpload, uploads, type UploadItem } from "./uploads";

const props = defineProps<{ tree: Tree; root: string }>();

const items = computed(() => uploads.items.filter((u) => u.tree === props.tree));
const pct = (u: UploadItem) => (u.size ? Math.min(100, Math.round((100 * u.sent) / u.size)) : u.state === "yukleniyor" ? 0 : 100);
const live = (u: UploadItem) => u.state === "sirada" || u.state === "yukleniyor";

function stateText(u: UploadItem): string {
  if (u.state === "sirada") return "sırada";
  if (u.state === "yukleniyor") return `%${pct(u)}`;
  if (u.state === "atlandi") return `atlandı: ${u.reason}`;
  return `yüklenemedi: ${u.reason}`;
}
</script>

<template>
  <section v-if="items.length" class="files-uploads" aria-labelledby="yuklemeler-baslik" data-testid="uploads">
    <h3 id="yuklemeler-baslik" class="files-uploads-title">Yüklemeler</h3>
    <ul class="files-upload-list">
      <li v-for="u in items" :key="u.id" class="files-upload" :class="'files-upload-' + u.state" :data-yukleme="u.name" :data-durum="u.state">
        <span class="files-upload-icon" aria-hidden="true"><Icon :name="u.state === 'hata' || u.state === 'atlandi' ? 'alert' : 'upload'" :size="18" /></span>
        <span class="files-upload-text">
          <strong class="wrap">{{ u.name }}</strong>
          <span class="cell-note"><span class="mono wrap">{{ fullPath(root, u.folder) }}</span><template v-if="u.size"> · {{ bytes(u.size) }}</template></span>
          <UsageBar v-if="u.state === 'yukleniyor'" :value="pct(u)" />
          <span class="files-upload-state" data-testid="upload-state">{{ stateText(u) }}</span>
        </span>
        <button type="button" class="icon-btn" :aria-label="`${live(u) ? 'Yüklemeyi iptal et' : 'Satırı kaldır'}: ${u.name}`" :title="live(u) ? 'İptal' : 'Kaldır'"
          :data-eylem="live(u) ? 'iptal' : 'kaldir'" @click="cancelUpload(u.id)">
          <Icon name="close" :size="18" />
        </button>
      </li>
    </ul>
  </section>
</template>
