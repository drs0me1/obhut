<!-- The switch (DD-258 goal 5): an on/off button with role="switch". `v-model` for a draft or a form; a page
     whose switch acts at once (a device on or off) listens to update:modelValue and lets the server decide,
     so the switch shows the server's state again after a refusal. The label is always the accessible name;
     `hideLabel` keeps it for screen readers only (a table row that already names the thing). -->
<script setup lang="ts">
withDefaults(defineProps<{ modelValue: boolean; label: string; disabled?: boolean; hideLabel?: boolean; describedby?: string; busy?: boolean }>(), {
  disabled: false,
  hideLabel: false,
  describedby: undefined,
  busy: false,
});
const emit = defineEmits<{ "update:modelValue": [value: boolean] }>();
</script>

<template>
  <button
    type="button"
    role="switch"
    class="switch"
    :class="{ 'switch-quiet': hideLabel }"
    :aria-checked="modelValue"
    :aria-describedby="describedby"
    :aria-busy="busy || undefined"
    :disabled="disabled"
    @click="emit('update:modelValue', !modelValue)"
  >
    <span class="switch-track" aria-hidden="true"><span class="switch-thumb"></span></span>
    <span :class="{ 'sr-only': hideLabel }">{{ label }}</span>
  </button>
</template>
