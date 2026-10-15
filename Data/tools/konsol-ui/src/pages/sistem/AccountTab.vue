<!-- Sistem → Hesap (DD-194, DD-205): the Konsol account and this browser's session as the backend names them
     (GET /api/konsol/oturum: kurulum, acik or giris, and the channel). The tailnet asks for no sign-in: the
     device is the credential, and from there the account is created (the internet name opens only with
     it) and its password set without the current one, which ends every session. On the internet channel the
     current password is asked, this browser stays signed in and the others end; "Çıkış yap" ends this one.
     The fields follow master_auth's rules (user 3–32 characters, password 10–256 without control characters);
     the server checks them again. ?parola=1 opens the password form. -->
<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from "vue";
import { Icon } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import Field from "../../components/ui/Field.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import { changePassword, createAccount } from "../../api/sistem";
import { canSignOut, internetChannel, leave, loadSession, session } from "./session";
import { useLeaveGuard } from "../../leave";
import { useQueryFlag } from "../../query";
import { UNKNOWN } from "../../format";

const USER_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{2,31}$/;
const CONTROL_RE = /[\u0000-\u001f\u007f]/;
const USER_RULE = "Kullanıcı adı 3–32 karakter olmalı: harf, rakam veya . _ - (ilk karakter harf ya da rakam).";
const PASSWORD_RULE = "Parola 10–256 karakter olmalı ve kontrol karakteri içermemeli.";
const passwordError = (p: string) => ([...p].length < 10 || [...p].length > 256 || CONTROL_RE.test(p) ? PASSWORD_RULE : "");

const s = computed(() => session.value);
const CHANNEL: Record<string, string> = { tailscale: "Tailscale", internet: "İnternet adresi", yerel: "Bu sunucu (yerel)" };
const hasAccount = computed(() => s.value?.durum === "acik" || s.value?.durum === "giris");
const noteText = computed(() => {
  const a = s.value;
  if (!a) return "";
  if (internetChannel.value) {
    return a.durum === "acik" ? `Giriş yapan: ${a.kullanici ?? UNKNOWN}. Oturum ${a.oturum_gun ?? 7} gün açık kalır.` : "Bu adres Konsol hesabıyla açılır.";
  }
  if (a.durum === "kurulum") {
    return "Tailscale'den giriş parolasızdır. İnternet adresi için bir kullanıcı adı ve parola belirleyin; hesap olmadan Konsol internete açılmaz.";
  }
  return `İnternet hesabı: ${a.kullanici ?? UNKNOWN}. Tailscale'den giriş parolasızdır; internet adresi bu hesapla açılır.`;
});

// ---- the forms
const note = ref("");
const passwordOpen = useQueryFlag("parola");
const createForm = ref({ user: "", password: "", again: "" });
const createTried = ref(false);
const createError = ref("");
const creating = ref(false);
const createErrors = computed(() => {
  const f = createForm.value;
  return {
    user: USER_RE.test(f.user.trim()) ? "" : USER_RULE,
    password: passwordError(f.password),
    again: f.again === f.password ? "" : "Parolalar aynı değil.",
  };
});

async function create(): Promise<void> {
  createTried.value = true;
  const e = createErrors.value;
  if (e.user || e.password || e.again || creating.value) return;
  creating.value = true;
  createError.value = "";
  note.value = "";
  try {
    await createAccount(createForm.value.user.trim(), createForm.value.password);
    createForm.value = { user: "", password: "", again: "" };
    createTried.value = false;
    note.value = "Konsol hesabı oluşturuldu; internet adresi bu hesapla açılır.";
    await loadSession(true);
    // The form is gone with the account's creation: focus goes to what follows it.
    void nextTick(() => passwordButton.value?.focus());
  } catch (err) {
    createError.value = err instanceof Error ? err.message : String(err);
  } finally {
    creating.value = false;
  }
}

const passwordForm = ref({ old: "", password: "", again: "" });
const passwordTried = ref(false);
const passwordFailure = ref("");
const changing = ref(false);
const changeErrors = computed(() => {
  const f = passwordForm.value;
  return {
    old: internetChannel.value && !f.old ? "Mevcut parolayı yazın." : "",
    password: passwordError(f.password),
    again: f.again === f.password ? "" : "Yeni parolalar aynı değil.",
  };
});

const passwordCard = ref<HTMLElement | null>(null);
const passwordButton = ref<HTMLButtonElement | null>(null);

// The form opens and closes with the address (the router answers a moment later): focus moves once the
// form, or the button that replaces it, is on the page.
let focusNext: "form" | "button" | "" = "";
watch(passwordOpen, () => {
  const where = focusNext;
  focusNext = "";
  if (where === "form") passwordCard.value?.querySelector<HTMLInputElement>("input")?.focus();
  else if (where === "button") passwordButton.value?.focus();
}, { flush: "post" });

function openPassword(): void {
  focusNext = "form";
  passwordOpen.value = true;
}

function closePassword(returnFocus = false): void {
  focusNext = returnFocus && passwordOpen.value ? "button" : "";
  passwordOpen.value = false;
  passwordForm.value = { old: "", password: "", again: "" };
  passwordTried.value = false;
  passwordFailure.value = "";
}

async function change(): Promise<void> {
  passwordTried.value = true;
  const e = changeErrors.value;
  if (e.old || e.password || e.again || changing.value) return;
  changing.value = true;
  passwordFailure.value = "";
  note.value = "";
  const internet = internetChannel.value;
  try {
    await changePassword(passwordForm.value.password, internet ? passwordForm.value.old : undefined);
    closePassword(true);
    note.value = internet ? "Konsol parolası değişti; diğer oturumlar kapatıldı." : "Konsol parolası değişti; internet oturumları kapatıldı.";
    await loadSession(true);
  } catch (err) {
    passwordFailure.value = err instanceof Error ? err.message : String(err);
    passwordForm.value.old = "";
  } finally {
    changing.value = false;
  }
}

// A typed password is a draft: closing or reloading the browser tab asks first.
useLeaveGuard(() => [createForm.value.user, createForm.value.password, createForm.value.again, passwordForm.value.old, passwordForm.value.password, passwordForm.value.again].some(Boolean));

const signingOut = ref(false);
async function signOutNow(): Promise<void> {
  signingOut.value = true;
  await leave();
}

onMounted(() => void loadSession(true));
</script>

<template>
  <div class="system-tab" data-testid="account-tab">
    <section class="card" aria-labelledby="hesap-baslik" data-testid="account">
      <div class="card-head">
        <h2 id="hesap-baslik" class="card-title">Konsol hesabı</h2>
        <div v-if="s" class="card-actions">
          <StatusPill :tone="hasAccount ? 'ok' : 'neutral'" data-testid="account-state">{{ hasAccount ? "Hesap var" : "Hesap yok" }}</StatusPill>
        </div>
      </div>
      <template v-if="s">
        <dl class="facts" data-testid="account-facts">
          <dt>Bağlantı</dt>
          <dd data-testid="account-channel">{{ CHANNEL[s.kanal] ?? s.kanal }}</dd>
          <dt>Hesap</dt>
          <dd data-testid="account-user">{{ hasAccount ? s.kullanici || UNKNOWN : "Henüz yok" }}</dd>
          <template v-if="internetChannel && s.durum === 'acik'">
            <dt>Oturum</dt>
            <dd data-testid="account-session">Açık · {{ s.oturum_gun ?? 7 }} gün geçerli</dd>
          </template>
        </dl>
        <p class="card-text" data-testid="account-note">{{ noteText }}</p>
        <div class="action-line">
          <button v-if="hasAccount && !passwordOpen" ref="passwordButton" type="button" class="btn btn-secondary" data-testid="password-open" @click="openPassword">
            <Icon name="key" :size="16" />Parolayı değiştir
          </button>
          <button v-if="canSignOut" type="button" class="btn btn-secondary" :disabled="signingOut" data-testid="account-sign-out" @click="signOutNow">
            <Icon name="power" :size="16" />Çıkış yap
          </button>
        </div>
        <p class="sr-only" role="status">{{ note }}</p>
        <p v-if="note" class="notice notice-ok" aria-hidden="true" data-testid="account-done"><Icon name="check" class="notice-icon" /><span>{{ note }}</span></p>
      </template>
      <EmptyState v-else :title="session.failed ? 'Hesap bilgisi okunamadı' : 'Hesap bilgisi okunuyor'" icon="key">
        <button v-if="session.failed" type="button" class="btn btn-secondary" @click="loadSession(true)">Yeniden dene</button>
      </EmptyState>
    </section>

    <section v-if="s && s.durum === 'kurulum'" class="card" aria-labelledby="hesap-kur-baslik" data-testid="account-create">
      <h2 id="hesap-kur-baslik" class="card-title">İnternet hesabı oluştur</h2>
      <p v-if="internetChannel" class="notice" role="note" data-testid="account-create-lock">
        <Icon name="lock" class="notice-icon" /><span>Konsol hesabı yalnız Tailscale adresinden oluşturulur.</span>
      </p>
      <form v-else class="form-stack account-form" novalidate @submit.prevent="create">
        <Field v-slot="{ id, describedby, invalid }" label="Kullanıcı adı" :error="createTried ? createErrors.user : ''" hint="3–32 karakter: harf, rakam ya da . _ -">
          <input :id="id" v-model="createForm.user" class="input" type="text" autocomplete="username" autocapitalize="none" spellcheck="false" maxlength="32"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" />
        </Field>
        <Field v-slot="{ id, describedby, invalid }" label="Parola" :error="createTried ? createErrors.password : ''" hint="En az 10 karakter.">
          <input :id="id" v-model="createForm.password" class="input" type="password" autocomplete="new-password" maxlength="256"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" />
        </Field>
        <Field v-slot="{ id, describedby, invalid }" label="Parola (tekrar)" :error="createTried ? createErrors.again : ''">
          <input :id="id" v-model="createForm.again" class="input" type="password" autocomplete="new-password" maxlength="256"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" />
        </Field>
        <p class="meter-note">Kayıt sunucuda yalnız özet olarak tutulur. Tailscale'den giriş parolasızdır; bu hesap yalnız internet adresinde sorulur.</p>
        <p v-if="createError" class="form-error" role="alert" data-testid="account-create-error">{{ createError }}</p>
        <button type="submit" class="btn btn-primary fit" :disabled="creating" data-testid="account-create-go">
          <Icon name="key" :size="16" />{{ creating ? "Oluşturuluyor…" : "Hesabı oluştur" }}
        </button>
      </form>
    </section>

    <section v-if="s && hasAccount && passwordOpen" ref="passwordCard" class="card" aria-labelledby="parola-baslik" data-testid="password">
      <h2 id="parola-baslik" class="card-title">Konsol parolası</h2>
      <form class="form-stack account-form" novalidate @submit.prevent="change">
        <Field v-if="internetChannel" v-slot="{ id, describedby, invalid }" label="Mevcut parola" :error="passwordTried ? changeErrors.old : ''">
          <input :id="id" v-model="passwordForm.old" class="input" type="password" autocomplete="current-password" maxlength="256"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" />
        </Field>
        <Field v-slot="{ id, describedby, invalid }" label="Yeni parola" :error="passwordTried ? changeErrors.password : ''" hint="En az 10 karakter.">
          <input :id="id" v-model="passwordForm.password" class="input" type="password" autocomplete="new-password" maxlength="256"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" />
        </Field>
        <Field v-slot="{ id, describedby, invalid }" label="Yeni parola (tekrar)" :error="passwordTried ? changeErrors.again : ''">
          <input :id="id" v-model="passwordForm.again" class="input" type="password" autocomplete="new-password" maxlength="256"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" />
        </Field>
        <p class="meter-note" data-testid="password-note">
          {{ internetChannel ? "Bu tarayıcı açık kalır; diğer tüm oturumlar kapanır." : "Tailscale cihazından mevcut parola sorulmaz; internet adresindeki tüm oturumlar kapanır." }}
        </p>
        <p v-if="passwordFailure" class="form-error" role="alert" data-testid="password-error">{{ passwordFailure }}</p>
        <div class="action-line">
          <button type="submit" class="btn btn-primary" :disabled="changing" data-testid="password-go">
            <Icon name="key" :size="16" />{{ changing ? "Değiştiriliyor…" : "Parolayı değiştir" }}
          </button>
          <button type="button" class="btn btn-secondary" @click="closePassword(true)">Vazgeç</button>
        </div>
      </form>
    </section>
  </div>
</template>
