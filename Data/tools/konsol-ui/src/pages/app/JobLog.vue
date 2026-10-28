<!-- A job's log (Uygulama ekle's Kurulum and an image's draft): each line with its local time; a step that began,
     a fact, a container's own output (after an install whose container did not come up), why the job failed and
     its end. The newest line scrolls into view while the reader is at the bottom; "Kopyala" copies the lines as
     text. -->
<script setup lang="ts">
import { nextTick, ref, watch } from "vue";
import { Icon, type IconName } from "../../components/icons";
import { copyText } from "../../clipboard";
import { clockSeconds } from "../../format";
import type { IsSatiri } from "../../api/sema";

const props = defineProps<{ lines: readonly IsSatiri[]; label: string }>();

const KIND: Record<IsSatiri["tur"], { icon: IconName | null; spoken: string }> = {
  adim: { icon: "chevron", spoken: "" },
  bilgi: { icon: "check", spoken: "" },
  cikti: { icon: null, spoken: "Konteyner: " },
  hata: { icon: "xcircle", spoken: "Hata: " },
  tamam: { icon: "check", spoken: "Bitti: " },
};

const box = ref<HTMLElement | null>(null);
const copied = ref("");
let follow = true;

function onScroll(): void {
  const b = box.value;
  if (b) follow = b.scrollTop + b.clientHeight >= b.scrollHeight - 8;
}

watch(
  () => props.lines.length,
  () => {
    if (!follow) return;
    void nextTick(() => {
      const b = box.value;
      if (b) b.scrollTop = b.scrollHeight;
    });
  },
  { immediate: true },
);

async function copy(): Promise<void> {
  const ok = await copyText(props.lines.map((l) => `${clockSeconds(l.t)} ${l.ileti}`).join("\n"));
  copied.value = ok ? "Kopyalandı." : "Kopyalanamadı; satırları seçip kopyalayın.";
}
</script>

<template>
  <div class="job-log-wrap">
    <div class="log-toolbar">
      <span class="meter-note" role="status">{{ copied }}</span>
      <button type="button" class="btn btn-secondary btn-sm" :disabled="!lines.length" data-eylem="kopyala" @click="copy">
        <Icon name="copy" :size="16" />Kopyala
      </button>
    </div>
    <div ref="box" class="log job-log" role="log" tabindex="0" :aria-label="label" data-testid="job-log" @scroll="onScroll">
      <ol>
        <li v-for="(l, i) in lines" :key="i" :class="'job-' + l.tur" :data-tur="l.tur">
          <span class="job-time">{{ clockSeconds(l.t) }}</span>
          <span class="job-mark" aria-hidden="true"><Icon v-if="KIND[l.tur]?.icon" :name="KIND[l.tur].icon!" :size="13" /></span>
          <span class="job-text"><span v-if="KIND[l.tur]?.spoken" class="sr-only">{{ KIND[l.tur].spoken }}</span>{{ l.ileti }}</span>
        </li>
      </ol>
      <p v-if="!lines.length" class="job-empty">Başlatılıyor…</p>
    </div>
  </div>
</template>
