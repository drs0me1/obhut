<!-- A package's first-login account (PAKET_HESAP, DD-149, DD-151; GET /api/konsol/uygulamalar/hesap): the
     address, the user and, while the package still runs with a temporary password, that password, which is
     fetched only when asked (Göster, or copy) with ?parola=1 (the server audits it), shown for 30 s and
     hidden at once when the browser tab is hidden; nothing reads it again on its own. A package without an
     account answers 404 and the card is not shown (`none`). -->
<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from "vue";
import { Icon } from "../../components/icons";
import Card from "../../components/ui/Card.vue";
import CopyButton from "../../components/ui/CopyButton.vue";
import { readAccount } from "../../api/uygulama";
import { ApiError } from "../../api/http";
import { copyText } from "../../clipboard";
import { message } from "./flows";
import type { Uygulama, UygulamaHesabi } from "../../api/sema";

const REVEAL_SECONDS = 30;
const props = defineProps<{ app: Uygulama }>();
const emit = defineEmits<{ none: [] }>();

const account = ref<UygulamaHesabi | null>(null);
const error = ref("");
const hidden = ref(false);
const pass = ref("");
const left = ref(0);
const revealError = ref("");
const copied = ref<"" | "ok" | "fail">("");
let timer = 0;
let copiedTimer = 0;

async function load(): Promise<void> {
  try {
    const value = await readAccount(props.app.id);
    account.value = { user: value.user, temp: value.temp, host: value.host };
    error.value = "";
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) {
      hidden.value = true;
      emit("none");
    } else error.value = message(err);
  }
}

function hide(): void {
  clearInterval(timer);
  timer = 0;
  pass.value = "";
  left.value = 0;
}

async function fetchPass(): Promise<string> {
  const value = await readAccount(props.app.id, true);
  return value.pass ?? "";
}

async function reveal(): Promise<void> {
  if (pass.value) {
    hide();
    return;
  }
  revealError.value = "";
  try {
    const value = await fetchPass();
    if (!value) throw new Error("Geçici parola artık yok; uygulama kalıcı bir parolayla çalışıyor olabilir.");
    hide();
    pass.value = value;
    left.value = REVEAL_SECONDS;
    timer = window.setInterval(() => {
      left.value -= 1;
      if (left.value <= 0) hide();
    }, 1000);
  } catch (err) {
    revealError.value = message(err);
  }
}

async function copyPass(): Promise<void> {
  revealError.value = "";
  clearTimeout(copiedTimer);
  let value = pass.value;
  try {
    if (!value) value = await fetchPass();
  } catch (err) {
    revealError.value = message(err);
    return;
  }
  copied.value = value && (await copyText(value)) ? "ok" : "fail";
  value = "";
  copiedTimer = window.setTimeout(() => (copied.value = ""), copied.value === "ok" ? 1500 : 4000);
}

function onVisibility(): void {
  if (document.hidden) hide();
}

onMounted(() => {
  document.addEventListener("visibilitychange", onVisibility);
  void load();
});
onBeforeUnmount(() => {
  document.removeEventListener("visibilitychange", onVisibility);
  clearTimeout(copiedTimer);
  hide();
});

// The address the operator opens: the application's own name for this channel, else the tailnet name.
const address = computed(() => {
  const https = location.protocol === "https:";
  const url = (https ? props.app.adres.internet : props.app.adres.tailscale) ?? props.app.adres.tailscale ?? props.app.adres.internet;
  if (url) return url.replace(/^[a-z]+:\/\//, "").replace(/\/$/, "");
  return account.value?.host ?? "";
});
</script>

<template>
  <Card v-if="!hidden" title="İlk giriş bilgileri" data-testid="account-card">
    <p v-if="error" class="form-error" role="alert">Hesap okunamadı: {{ error }}</p>
    <p v-else-if="!account" class="meter-note">Hesap okunuyor…</p>
    <template v-else>
      <dl class="facts cred-facts">
        <template v-if="address">
          <dt>Adres</dt>
          <dd class="cred-value"><span class="mono wrap" data-testid="account-address">{{ address }}</span><CopyButton :text="address" label="Adres" /></dd>
        </template>
        <dt>Kullanıcı</dt>
        <dd class="cred-value"><span class="mono wrap" data-testid="account-user">{{ account.user }}</span><CopyButton :text="account.user" label="Kullanıcı" /></dd>
        <template v-if="account.temp">
          <dt>Geçici parola</dt>
          <dd class="cred-value">
            <span class="mono" :class="{ masked: !pass }" data-testid="account-pass">{{ pass || "•••••••••" }}</span>
            <button
              type="button"
              class="icon-btn"
              :aria-label="pass ? 'Geçici parolayı gizle' : 'Geçici parolayı göster'"
              :title="pass ? 'Gizle' : 'Göster'"
              :aria-pressed="Boolean(pass)"
              data-testid="account-reveal"
              @click="reveal"
            >
              <Icon :name="pass ? 'eyeOff' : 'eye'" :size="18" />
            </button>
            <span class="copy-button">
              <button type="button" class="icon-btn" aria-label="Geçici parolayı kopyala" title="Geçici parolayı kopyala" data-testid="account-copy" @click="copyPass">
                <Icon :name="copied === 'ok' ? 'check' : 'copy'" :size="18" />
              </button>
              <span class="sr-only" role="status">{{ copied === "ok" ? "Geçici parola kopyalandı." : "" }}</span>
              <span v-if="copied === 'fail'" class="meter-note warn-text" role="alert">Pano kullanılamadı; parolayı gösterip seçerek kopyalayın.</span>
            </span>
          </dd>
        </template>
      </dl>
      <p v-if="pass" class="meter-note" role="status" data-testid="account-left">{{ left }} sn sonra gizlenir</p>
      <p v-if="revealError" class="form-error" role="alert" data-testid="account-error">{{ revealError }}</p>
      <p class="meter-note" data-testid="account-note">
        {{
          account.temp
            ? "Uygulama ilk açılışta geçici bir parola kullanır ve yeniden başlatmada değişebilir. Girişten sonra kalıcı bir parola belirleyin."
            : "Parola kayıtlı; Konsol kayıtlı parolayı göstermez."
        }}
      </p>
    </template>
  </Card>
</template>
