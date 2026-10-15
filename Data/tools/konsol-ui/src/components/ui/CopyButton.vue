<!-- Copy one value (DD-266): an icon button named after what it copies. It shows a check for a moment
     after copying; when the clipboard cannot be used it says so in a status line, and the value stays on
     the page to be selected by hand. -->
<script setup lang="ts">
import { onBeforeUnmount, ref } from "vue";
import { copyText } from "../../clipboard";
import { Icon } from "../icons";

const props = withDefaults(defineProps<{ text: string; label: string; disabled?: boolean }>(), { disabled: false });

const state = ref<"" | "ok" | "fail">("");
let timer = 0;

async function copy(): Promise<void> {
  clearTimeout(timer);
  state.value = (await copyText(props.text)) ? "ok" : "fail";
  timer = window.setTimeout(() => (state.value = ""), state.value === "ok" ? 1500 : 4000);
}

onBeforeUnmount(() => clearTimeout(timer));
</script>

<template>
  <span class="copy-button">
    <button
      type="button"
      class="icon-btn"
      :disabled="disabled"
      :aria-label="`${label} kopyala`"
      :title="`${label} kopyala`"
      data-eylem="kopyala"
      @click="copy"
    >
      <Icon :name="state === 'ok' ? 'check' : 'copy'" :size="18" />
    </button>
    <span class="sr-only" role="status">{{ state === "ok" ? `${label} kopyalandı.` : "" }}</span>
    <span v-if="state === 'fail'" class="meter-note warn-text" role="alert">Pano kullanılamadı; değeri seçip kopyalayın.</span>
  </span>
</template>
