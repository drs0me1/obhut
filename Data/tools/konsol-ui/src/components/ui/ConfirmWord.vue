<!-- The typed confirmation (DD-258 goal 5; the security floor: an irreversible action needs a typed word).
     `confirmed` turns true once the field holds the word, compared with Turkish case rules and without
     surrounding spaces, as in the current Konsol ("ONAYLA" counts, "onay" does not). -->
<script setup lang="ts">
import { computed, ref, useId, watch } from "vue";
import { fold } from "../../format";

const props = withDefaults(defineProps<{ word?: string }>(), { word: "onayla" });
const confirmed = defineModel<boolean>("confirmed", { default: false });

const id = useId();
const text = ref("");
const matches = computed(() => fold(text.value.trim()) === fold(props.word));
watch(matches, (ok) => (confirmed.value = ok), { immediate: true });
</script>

<template>
  <div class="confirm-word">
    <label :for="id" class="field-label">Onaylamak için <strong class="confirm-word-text">{{ word }}</strong> yazın</label>
    <input
      :id="id"
      v-model="text"
      class="input"
      type="text"
      autocomplete="off"
      autocapitalize="off"
      spellcheck="false"
      data-autofocus
    />
  </div>
</template>
