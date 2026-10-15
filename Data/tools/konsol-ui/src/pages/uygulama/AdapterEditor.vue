<!-- An App Store package's container settings (DD-219, DD-221; the Podman page's adapter editor): only the
     fields its adapter declares (`editable`): the interface port on 127.0.0.1, the peer port when it has one,
     the save folder through the picker. The package's protected mounts are shown, never edited. The review
     lists each change and what it does (a running application restarts; a new peer port closes the old one
     on the internet), then POST …/konteynerler/islem {action:"save", name, revision, config:{listener_port,
     peer_port?, save}, start:false}: the package keeps a stopped application stopped. -->
<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { Icon } from "../../components/icons";
import Card from "../../components/ui/Card.vue";
import Field from "../../components/ui/Field.vue";
import FolderPicker from "../../components/ui/FolderPicker.vue";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import ChangeReview from "./ChangeReview.vue";
import { useContainerSave } from "./save";
import { useLeaveGuard } from "../../leave";
import type { Change, Consequence } from "./container";
import type { AdapterConfig, ContainerDetail } from "../../api/podman";

const props = defineProps<{ box: ContainerDetail & { adapter: AdapterConfig } }>();
const emit = defineEmits<{ saved: []; reload: [] }>();

interface AdapterDraft {
  listener: string;
  peer: string | null;
  save: string | null;
}
const fromConfig = (c: AdapterConfig): AdapterDraft => ({
  listener: String(c.listener_port),
  peer: c.peer_port !== undefined ? String(c.peer_port) : null,
  save: c.save !== undefined ? c.save : null,
});
const draft = ref<AdapterDraft>(fromConfig(props.box.adapter));
const tried = ref(false);
const reviewOpen = ref(false);
const done = ref("");
const save = useContainerSave();
let takeNext = false;

const orig = computed(() => props.box.adapter);
const can = (field: string) => props.box.editable.includes(field);
const running = computed(() => props.box.state === "running");
const port = (text: string) => (/^\d{1,5}$/.test(text.trim()) ? Number(text.trim()) : NaN);
const inRange = (n: number) => Number.isInteger(n) && n >= 1024 && n <= 65535;

const errors = computed(() => {
  const out: Record<string, string> = {};
  const listener = port(draft.value.listener);
  if (!inRange(listener)) out.listener = "Arayüz portu 1024–65535 arasında bir sayı olmalı.";
  if (draft.value.peer !== null) {
    const peer = port(draft.value.peer);
    if (!inRange(peer)) out.peer = "Eş portu 1024–65535 arasında bir sayı olmalı.";
    else if (peer === listener) out.peer = "Eş portu arayüz portundan farklı olmalı.";
  }
  if (draft.value.save !== null && !/^\/[^\0]*$/.test(draft.value.save.trim())) out.save = "Kayıt klasörünü seçin.";
  return out;
});

const list = computed<Change[]>(() => {
  const out: Change[] = [];
  const o = orig.value;
  const d = draft.value;
  if (String(o.listener_port) !== d.listener.trim()) out.push({ kind: "chg", field: "Arayüz portu", before: String(o.listener_port), after: d.listener.trim() });
  if (d.peer !== null && String(o.peer_port) !== d.peer.trim()) out.push({ kind: "chg", field: "Eş portu", before: String(o.peer_port ?? "—"), after: d.peer.trim() });
  if (d.save !== null && (o.save ?? "") !== d.save) out.push({ kind: "chg", field: "Kayıt klasörü", before: o.save || "—", after: d.save });
  return out;
});
const effects = computed<Consequence[]>(() => {
  const out: Consequence[] = [
    running.value
      ? { tone: "warn", text: "Uygulama durdurulup yeni ayarlarla yeniden başlatılır; bu sırada kısa süre erişilemez." }
      : { tone: "ok", text: "Uygulama durmuş olduğu için kesinti olmaz: ayarlar kaydedilir ve uygulama durmuş kalır." },
  ];
  if (list.value.some((c) => c.field === "Kayıt klasörü")) out.push({ tone: "warn", text: "Klasör değişikliği dosya taşımaz; var olan dosyalar eski yerinde kalır." });
  if (list.value.some((c) => c.field === "Eş portu")) {
    out.push({ tone: "warn", text: "Eski eş portu internete kapanır, yenisi WAN IPv4 adresinde TCP ve UDP olarak açılır; eşler yeni portu bir sonraki duyuruda öğrenir." });
  }
  out.push({ tone: "info", text: "Uygulamanın ayarı, hizmeti, Caddy yönlendirmesi ve denetimleri aynı değerle birlikte güncellenir." });
  return out;
});
const dirty = computed(() => list.value.length > 0);
useLeaveGuard(dirty);

watch(
  () => props.box.revision,
  () => {
    if (takeNext || !dirty.value) {
      takeNext = false;
      draft.value = fromConfig(props.box.adapter);
      tried.value = false;
    }
  },
);

function review(): void {
  done.value = "";
  if (Object.keys(errors.value).length) {
    tried.value = true;
    return;
  }
  save.clear();
  reviewOpen.value = true;
}

async function apply(): Promise<void> {
  const config: AdapterConfig = { listener_port: port(draft.value.listener) };
  if (draft.value.peer !== null) config.peer_port = port(draft.value.peer);
  if (draft.value.save !== null) config.save = draft.value.save;
  else if (orig.value.save !== undefined) config.save = orig.value.save;
  const ok = await save.send({ action: "save", name: props.box.name, revision: props.box.revision, config, start: false }, running.value ? "Uygulama yeniden başlatılıyor…" : "Ayarlar kaydediliyor…");
  if (!ok) return;
  takeNext = true;
  reviewOpen.value = false;
  done.value = "Değişiklikler uygulandı.";
  emit("saved");
}

function reload(): void {
  takeNext = true;
  reviewOpen.value = false;
  save.clear();
  emit("reload");
}

function discard(): void {
  draft.value = fromConfig(props.box.adapter);
  tried.value = false;
}

function closeReview(): void {
  if (save.state.value === "sending") return;
  reviewOpen.value = false;
}

const err = (key: string) => (tried.value ? (errors.value[key] ?? "") : "");
const busy = computed(() => save.state.value === "sending" || save.state.value === "running");
</script>

<template>
  <Card title="Konteyner ayarları" data-testid="adapter">
    <p class="card-text muted">
      {{
        box.network === "host"
          ? "Sunucu ağını (host) kullanır; port eşlemesi yoktur. Arayüz portu uygulamanın kendi ayarına, hizmetine, Caddy yönlendirmesine ve denetimlerine birlikte uygulanır."
          : "Arayüz yalnız 127.0.0.1'de yayımlanır; dışarıdan Caddy üzerinden açılır. Yalnız paketin izin verdiği alanlar değişir."
      }}
    </p>
    <div class="form-stack">
      <Field v-slot="{ id, describedby, invalid }" label="Arayüz portu (yalnız 127.0.0.1)" :error="err('listener')">
        <input :id="id" v-model="draft.listener" class="input mono" type="text" inputmode="numeric" maxlength="5" autocomplete="off" :readonly="!can('listener_port')"
          :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-alan="listener" />
      </Field>
      <Field
        v-if="draft.peer !== null"
        v-slot="{ id, describedby, invalid }"
        label="Eş portu (WAN IPv4, TCP+UDP)"
        hint="Eşler bu porttan bağlanır. 61000–65535 arası önerilir: sunucunun giden bağlantılar için kullandığı 32768–60999 aralığının dışındadır."
        :error="err('peer')"
      >
        <input :id="id" v-model="draft.peer" class="input mono" type="text" inputmode="numeric" maxlength="5" autocomplete="off" :readonly="!can('peer_port')"
          :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-alan="peer" />
      </Field>
      <Field v-if="draft.save !== null" v-slot="{ id, describedby, invalid }" label="Kayıt klasörü (uygulama ayarı)" hint="Konteynerde aynı yolla görünür; var olan dosyalar taşınmaz." :error="err('save')">
        <FolderPicker :id="id" v-model="draft.save" name="Kayıt klasörü" :disabled="!can('save')" :describedby="describedby" :invalid="invalid" data-alan="save" />
      </Field>
      <ul v-if="box.protected.length" class="mount-list" aria-label="Korunan bağlamalar" data-testid="protected">
        <li v-for="m in box.protected" :key="m.destination" class="mount">
          <span class="mono">{{ m.source ? `${m.source} → ${m.destination}` : m.destination }}</span>
          <span class="mount-flag"><Icon name="lock" :size="14" />korunur · {{ (m.reason || "uygulama verisi").replace(/\.$/, "") }} · burada değiştirilemez</span>
        </li>
      </ul>
    </div>
    <p v-if="done" class="notice notice-ok" role="status" data-testid="adapter-done"><Icon name="check" class="notice-icon" /><span>{{ done }}</span></p>
    <div class="draft-bar">
      <span class="meter-note" role="status" data-testid="adapter-status">{{ dirty ? `${list.length} değişiklik; henüz kaydedilmedi.` : "Değişiklik yok." }}</span>
      <div class="draft-actions">
        <button v-if="dirty" type="button" class="btn btn-secondary" @click="discard">Değişiklikleri at</button>
        <button type="button" class="btn btn-primary" :disabled="!dirty" data-testid="adapter-review" @click="review">Gözden geçir</button>
      </div>
    </div>
  </Card>

  <Modal :open="reviewOpen" variant="sheet" title="Konteyner ayarları · değişiklikler" description="Henüz hiçbir şey değişmedi; Uygula'ya basınca kaydedilir." @close="closeReview">
    <div class="flow-step" data-testid="adapter-sheet">
      <ChangeReview :changes="list" :consequences="effects" />
      <div v-if="save.state.value === 'running'" class="flow-run" role="status" data-testid="adapter-run">
        <div class="flow-run-head">
          <strong>{{ box.name }}</strong>
          <StatusPill tone="accent">Sürüyor…</StatusPill>
        </div>
        <p class="cell-note">{{ save.step.value }}</p>
      </div>
      <div v-if="save.error.value" class="notice notice-danger" role="alert" data-testid="adapter-error">
        <Icon name="xcircle" class="notice-icon" />
        <div class="form-stack">
          <p><strong>Uygulanamadı.</strong> {{ save.error.value }}</p>
          <button v-if="save.stale.value" type="button" class="btn btn-secondary btn-sm fit" data-testid="adapter-reload" @click="reload"><Icon name="refresh" :size="16" />Güncel ayarları yükle</button>
        </div>
      </div>
    </div>
    <template #actions>
      <button type="button" class="btn btn-secondary" :disabled="busy" @click="closeReview">Düzenlemeye dön</button>
      <button type="button" class="btn btn-primary" :disabled="busy || save.stale.value" data-testid="adapter-apply" @click="apply">
        {{ save.state.value === "sending" ? "Gönderiliyor…" : save.state.value === "running" ? "Uygulanıyor…" : running ? "Uygula ve yeniden başlat" : "Kaydet" }}
      </button>
    </template>
  </Modal>
</template>
