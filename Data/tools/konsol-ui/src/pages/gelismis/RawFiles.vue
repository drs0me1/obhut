<!-- The raw configuration files behind a technical view (Caddy's sites, dnsmasq's names), read-only, each with
     its path and a copy button. Closed by default; opening it is in the address (?ham=1). -->
<script setup lang="ts">
import CopyButton from "../../components/ui/CopyButton.vue";
import { useQueryFlag } from "../../query";
import type { YapilandirmaDosyasi } from "../../api/sema";

defineProps<{ files: YapilandirmaDosyasi[]; summary: string }>();

const open = useQueryFlag("ham");
const base = (path: string) => path.split("/").pop() || path;
function onToggle(event: Event): void {
  open.value = (event.target as HTMLDetailsElement).open;
}
</script>

<template>
  <details class="card technical-card raw-files" :open="open" data-testid="raw" @toggle="onToggle">
    <summary>Ham yapılandırma <span class="muted raw-count">· {{ summary }}</span></summary>
    <p class="meter-note">Sunucudaki dosyalar olduğu gibi, salt okunur. Kurulum ve Konsol'un ayarları bu dosyaları üretir; değişiklikler Erişim'den yapılır.</p>
    <p v-if="!files.length" class="meter-note">Okunan dosya yok.</p>
    <section v-for="f in files" :key="f.file" class="raw-file" :aria-label="f.file" :data-dosya="base(f.file)">
      <div class="raw-head">
        <code class="mono raw-path">{{ f.file }}</code>
        <CopyButton :text="f.text" :label="base(f.file)" />
      </div>
      <pre class="log raw-text" tabindex="0" :aria-label="`${base(f.file)} içeriği`">{{ f.text.trim() || "(boş)" }}</pre>
    </section>
  </details>
</template>
