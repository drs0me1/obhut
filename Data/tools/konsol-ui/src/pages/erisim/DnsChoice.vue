<!-- The DNS choice of a WireGuard device or network (as magaza/wireguard/sayfa.js): five providers and
     "Özel" with the operator's own addresses. v-model is the normalised list ("1.1.1.1, 1.0.0.1, …"), or ""
     while "Özel" holds nothing valid; `badge` marks a choice ("şu an", "ağın varsayılanı", "önerilen"). -->
<script setup lang="ts">
import { computed, ref, useId, watch } from "vue";
import Field from "../../components/ui/Field.vue";
import { DNS_PRESETS, normDns } from "./wg";

const props = withDefaults(defineProps<{ label: string; badge?: (ips: string | null) => string; disabled?: boolean }>(), {
  badge: () => "",
  disabled: false,
});
const model = defineModel<string>({ required: true });

const name = useId();
const choice = ref<string>(DNS_PRESETS[0].ips);
const custom = ref("");

function set(ips: string): void {
  const preset = DNS_PRESETS.find((d) => d.ips === ips);
  choice.value = preset ? preset.ips : "custom";
  custom.value = preset ? "" : ips;
}
set(model.value || DNS_PRESETS[0].ips);

const value = computed(() => (choice.value === "custom" ? normDns(custom.value) ?? "" : choice.value));
watch(value, (v) => {
  if (v !== model.value) model.value = v;
}, { immediate: true });
// The parent set another value (a different device): follow it.
watch(model, (v) => {
  if (v !== value.value && v) set(v);
});

const error = computed(() => (choice.value === "custom" && custom.value.trim() !== "" && !normDns(custom.value) ? "Geçerli IPv4 ya da IPv6 adreslerini virgülle ayırarak yazın." : ""));
</script>

<template>
  <Field :label="label" group :error="error">
    <div class="dns-choices">
      <label v-for="d in DNS_PRESETS" :key="d.ips" class="dns-choice" :data-dns="d.name">
        <input v-model="choice" type="radio" :name="name" :value="d.ips" :disabled="disabled" />
        <span class="dns-choice-text">
          <span class="dns-choice-head"><strong>{{ d.name }}</strong><span v-if="props.badge(d.ips)" class="badge badge-neutral">{{ props.badge(d.ips) }}</span></span>
          <span class="dns-choice-meta"><template v-if="d.tag">{{ d.tag }} · </template><span class="mono">{{ d.ips }}</span></span>
        </span>
      </label>
      <label class="dns-choice" data-dns="Özel">
        <input v-model="choice" type="radio" :name="name" value="custom" :disabled="disabled" />
        <span class="dns-choice-text">
          <span class="dns-choice-head"><strong>Özel</strong><span v-if="props.badge(null)" class="badge badge-neutral">{{ props.badge(null) }}</span></span>
          <span class="dns-choice-meta">Kendi DNS adreslerinizi yazın; birden çoksa virgülle ayırın</span>
        </span>
      </label>
      <input
        v-if="choice === 'custom'"
        v-model="custom"
        class="input dns-custom"
        type="text"
        :aria-label="label + ' · özel adresler'"
        :aria-invalid="Boolean(error) || undefined"
        placeholder="ör. 192.0.2.53, 2001:db8::53"
        autocomplete="off"
        spellcheck="false"
        :disabled="disabled"
      />
    </div>
  </Field>
</template>
