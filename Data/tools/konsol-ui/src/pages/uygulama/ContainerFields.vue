<!-- The container definition's fields (DD-211, DD-227), as the current Konsol's Podman editor has them:
     the image (and on create the name), the network and the published ports (each with its scope, server
     and container port, protocol, and for an internet port the operator's acknowledgement), the mounts (a
     named volume, or a server folder through the picker; the path inside; read-only), the environment (a
     secret row's stored value never comes here: blank keeps it), the command (one argument per line), the
     account, start at boot, the restart policy and the CPU and memory limits. The draft is the parent's
     (container.ts); a field the server does not let change (`editable`) is read-only. Errors show once the
     parent says the operator tried to go on (`show`). -->
<script setup lang="ts">
import { computed, nextTick, ref, useId } from "vue";
import { Icon } from "../../components/icons";
import Field from "../../components/ui/Field.vue";
import FolderPicker from "../../components/ui/FolderPicker.vue";
import {
  DEFAULT_NETWORK,
  PUBLIC_RISK,
  RESTART_TEXT,
  USER_TEXT,
  newEnv,
  newMount,
  newPort,
  type Draft,
  type NetworkChoice,
  type Problems,
} from "./container";

const props = withDefaults(
  defineProps<{ draft: Draft; create: boolean; editable?: readonly string[] | null; networks: readonly NetworkChoice[]; volumes?: readonly string[]; errors: Problems; show: boolean }>(),
  { editable: null, volumes: () => [] },
);

const uid = useId();
const root = ref<HTMLElement | null>(null);
const can = (field: string) => props.create || !props.editable || props.editable.includes(field);
const err = (key: string) => (props.show ? (props.errors[key] ?? "") : "");
const errId = (key: string) => (err(key) ? `${uid}-${key}` : undefined);
const volumeList = `${uid}-birimler`;
const RESTARTS = Object.entries(RESTART_TEXT) as [Draft["restart"], string][];
const USERS = Object.entries(USER_TEXT) as [Draft["user"], string][];
const multipleNetworks = computed(() => props.networks.length > 1);

async function focusRow(kind: string, key: number): Promise<void> {
  await nextTick();
  root.value?.querySelector<HTMLElement>(`[data-satir="${kind}${key}"] :is(select, input):not([readonly]):not([disabled])`)?.focus();
}

async function focusAdd(kind: string): Promise<void> {
  await nextTick();
  root.value?.querySelector<HTMLElement>(`[data-ekle="${kind}"]`)?.focus();
}

function addPort(): void {
  const p = newPort();
  props.draft.ports.push(p);
  void focusRow("p", p.key);
}

function addMount(): void {
  const m = newMount();
  props.draft.mounts.push(m);
  void focusRow("m", m.key);
}

function addEnv(): void {
  const e = newEnv();
  props.draft.env.push(e);
  void focusRow("e", e.key);
}

function remove<T>(list: T[], index: number, kind: string): void {
  list.splice(index, 1);
  void focusAdd(kind);
}

function onScope(p: Draft["ports"][number]): void {
  if (p.scope !== "public") p.ack = false;
}

function onType(m: Draft["mounts"][number]): void {
  m.source = "";
}
</script>

<template>
  <div ref="root" class="container-fields">
    <fieldset class="form-section">
      <legend class="form-section-title"><Icon name="box" :size="18" />{{ create ? "İmaj ve ad" : "İmaj" }}</legend>
      <Field
        v-slot="{ id, describedby, invalid }"
        :label="create ? 'İmaj' : 'İmaj (etiket)'"
        :hint="!can('image') ? 'Bu konteynerde imaj değiştirilemez.' : create ? 'Çekildiğinde özete (sha256) sabitlenir; güncelleme yalnız sizin isteğinizle olur.' : 'Etiketi değiştirmek konteyneri yeni imajla yeniden oluşturur.'"
        :error="err('image')"
      >
        <input
          :id="id"
          v-model="draft.imageRef"
          class="input mono"
          type="text"
          autocomplete="off"
          autocapitalize="none"
          spellcheck="false"
          placeholder="docker.io/library/nginx:1.27-alpine"
          :readonly="!can('image')"
          :aria-describedby="describedby"
          :aria-invalid="invalid || undefined"
          data-alan="image"
        />
      </Field>
      <Field v-if="create" v-slot="{ id, describedby, invalid }" label="Ad" hint="Uygulamalar'da bu adla görünür; sonradan değişmez." :error="err('name')">
        <input
          :id="id"
          v-model="draft.name"
          class="input mono"
          type="text"
          maxlength="31"
          autocomplete="off"
          autocapitalize="none"
          spellcheck="false"
          placeholder="ornek-uygulama"
          :aria-describedby="describedby"
          :aria-invalid="invalid || undefined"
          data-alan="name"
        />
      </Field>
    </fieldset>

    <fieldset class="form-section">
      <legend class="form-section-title"><Icon name="globe" :size="18" />Ağ ve portlar</legend>
      <Field
        v-slot="{ id, describedby, invalid }"
        label="Ağ"
        :hint="draft.network === DEFAULT_NETWORK ? 'Sunucu bu ağı ilk kullanımda kendisi kurar.' : multipleNetworks ? 'Konsol\'un yönettiği köprü ağı.' : ''"
        :error="err('network')"
      >
        <select :id="id" v-model="draft.network" class="input" :disabled="!can('network')" :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-alan="network">
          <option v-for="n in networks" :key="n.value" :value="n.value">{{ n.label }}</option>
        </select>
      </Field>
      <p class="meter-note guard-line"><Icon name="lock" :size="16" /><span>Yeni port <strong>Yalnız bu sunucu</strong> ile başlar; Tailscale ve İnternet açıkça seçilir.</span></p>
      <ul v-if="draft.ports.length" class="edit-rows" aria-label="Portlar">
        <li v-for="(p, i) in draft.ports" :key="p.key" class="edit-row port-row" :data-satir="'p' + p.key" :aria-label="`${i + 1}. port`">
          <Field v-slot="{ id }" label="Erişim">
            <select :id="id" v-model="p.scope" class="input" :disabled="!can('ports')" :aria-describedby="errId('p' + p.key)" data-alan="scope" @change="onScope(p)">
              <option value="local">Yalnız bu sunucu</option>
              <option value="tailscale">Tailscale</option>
              <option value="public">İnternet (herkese açık)</option>
            </select>
          </Field>
          <Field v-slot="{ id }" label="Sunucu portu">
            <input :id="id" v-model="p.host" class="input mono" type="text" inputmode="numeric" maxlength="5" autocomplete="off" :readonly="!can('ports')"
              :aria-describedby="errId('p' + p.key)" :aria-invalid="Boolean(err('p' + p.key)) || undefined" data-alan="host" />
          </Field>
          <Field v-slot="{ id }" label="Konteyner portu">
            <input :id="id" v-model="p.inner" class="input mono" type="text" inputmode="numeric" maxlength="5" autocomplete="off" :readonly="!can('ports')"
              :aria-describedby="errId('p' + p.key)" :aria-invalid="Boolean(err('p' + p.key)) || undefined" data-alan="inner" />
          </Field>
          <Field v-slot="{ id }" label="Protokol">
            <select :id="id" v-model="p.protocol" class="input" :disabled="!can('ports')" data-alan="protocol">
              <option value="tcp">TCP</option>
              <option value="udp">UDP</option>
            </select>
          </Field>
          <button v-if="can('ports')" type="button" class="icon-btn icon-btn-danger row-remove" :aria-label="`${i + 1}. portu kaldır`" @click="remove(draft.ports, i, 'p')">
            <Icon name="trash" :size="18" />
          </button>
          <label v-if="p.scope === 'public' && !p.wasPublic" class="check-option row-wide public-ack" data-alan="ack">
            <input v-model="p.ack" type="checkbox" />
            <span>
              <strong>Bu portun internetten herkese açık olacağını anlıyorum</strong>
              <small>{{ PUBLIC_RISK }} Web uygulamaları için Erişim'deki Yayınla daha güvenlidir.</small>
            </span>
          </label>
          <p v-if="err('p' + p.key)" :id="errId('p' + p.key)" class="field-error row-wide">{{ err("p" + p.key) }}</p>
        </li>
      </ul>
      <p v-else class="meter-note">Port yayımlanmıyor; konteynere yalnız aynı ağdaki konteynerler ulaşır.</p>
      <button v-if="can('ports')" type="button" class="btn btn-secondary btn-sm fit" data-ekle="p" @click="addPort"><Icon name="plus" :size="16" />Port ekle</button>
    </fieldset>

    <fieldset class="form-section">
      <legend class="form-section-title"><Icon name="folder" :size="18" />Bağlamalar</legend>
      <p class="meter-note">Kalıcı veri yalnız bağlamalarda durur: konteyner yeniden oluşturulunca geri kalanı silinir. Bir bağlamanın yolunu değiştirmek dosya taşımaz.</p>
      <datalist :id="volumeList">
        <option v-for="v in volumes" :key="v" :value="v"></option>
      </datalist>
      <ul v-if="draft.mounts.length" class="edit-rows" aria-label="Bağlamalar">
        <li v-for="(m, i) in draft.mounts" :key="m.key" class="edit-row mount-row" :data-satir="'m' + m.key" :aria-label="`${i + 1}. bağlama`">
          <Field v-slot="{ id }" label="Tür">
            <select :id="id" v-model="m.type" class="input" :disabled="!can('mounts')" data-alan="type" @change="onType(m)">
              <option value="volume">Birim</option>
              <option value="bind">Sunucu klasörü</option>
            </select>
          </Field>
          <Field v-if="m.type === 'volume'" v-slot="{ id }" label="Birim adı" :hint="volumes.length ? 'Var olan bir birimi seçin ya da yeni bir ad yazın.' : 'Yeni birim bu adla oluşturulur.'">
            <input :id="id" v-model="m.source" class="input mono" type="text" :list="volumeList" autocomplete="off" autocapitalize="none" spellcheck="false"
              placeholder="ornek-veri" :readonly="!can('mounts')" :aria-describedby="errId('m' + m.key)" :aria-invalid="Boolean(err('m' + m.key)) || undefined" data-alan="source" />
          </Field>
          <Field v-else v-slot="{ id }" label="Sunucu klasörü">
            <FolderPicker :id="id" v-model="m.source" name="Sunucu klasörü" :disabled="!can('mounts')" :describedby="errId('m' + m.key)" :invalid="Boolean(err('m' + m.key))" data-alan="source" />
          </Field>
          <Field v-slot="{ id }" label="Konteynerdeki yol">
            <input :id="id" v-model="m.destination" class="input mono" type="text" autocomplete="off" autocapitalize="none" spellcheck="false" placeholder="/data"
              :readonly="!can('mounts')" :aria-describedby="errId('m' + m.key)" :aria-invalid="Boolean(err('m' + m.key)) || undefined" data-alan="destination" />
          </Field>
          <label class="check-row" data-alan="readonly"><input v-model="m.readOnly" type="checkbox" :disabled="!can('mounts')" />Salt okunur</label>
          <button v-if="can('mounts')" type="button" class="icon-btn icon-btn-danger row-remove" :aria-label="`${i + 1}. bağlamayı kaldır`" @click="remove(draft.mounts, i, 'm')">
            <Icon name="trash" :size="18" />
          </button>
          <p v-if="err('m' + m.key)" :id="errId('m' + m.key)" class="field-error row-wide">{{ err("m" + m.key) }}</p>
        </li>
      </ul>
      <p v-else class="meter-note">Bağlama yok.</p>
      <button v-if="can('mounts')" type="button" class="btn btn-secondary btn-sm fit" data-ekle="m" @click="addMount"><Icon name="plus" :size="16" />Bağlama ekle</button>
    </fieldset>

    <fieldset class="form-section">
      <legend class="form-section-title"><Icon name="key" :size="18" />Ortam</legend>
      <ul v-if="draft.env.length" class="edit-rows" aria-label="Ortam değişkenleri">
        <li v-for="(e, i) in draft.env" :key="e.key" class="edit-row env-row" :data-satir="'e' + e.key" :aria-label="e.name ? `${e.name} değişkeni` : `${i + 1}. değişken`">
          <Field v-slot="{ id }" label="Ad">
            <input :id="id" v-model="e.name" class="input mono" type="text" autocomplete="off" autocapitalize="none" spellcheck="false" placeholder="TZ"
              :readonly="!can('environment') || e.stored" :aria-describedby="errId('e' + e.key)" :aria-invalid="Boolean(err('e' + e.key)) || undefined" data-alan="env-name" />
          </Field>
          <Field v-slot="{ id }" label="Değer">
            <input :id="id" v-model="e.value" class="input mono" :type="e.secret ? 'password' : 'text'" :autocomplete="e.secret ? 'new-password' : 'off'" spellcheck="false"
              :placeholder="e.stored ? 'kayıtlı · boş bırakılırsa korunur' : ''" :readonly="!can('environment')" data-alan="env-value" />
          </Field>
          <label class="check-row" data-alan="secret"><input v-model="e.secret" type="checkbox" :disabled="!can('environment') || e.stored" />Gizli</label>
          <button v-if="can('environment')" type="button" class="icon-btn icon-btn-danger row-remove" :aria-label="`${e.name || i + 1 + '.'} değişkenini kaldır`" @click="remove(draft.env, i, 'e')">
            <Icon name="trash" :size="18" />
          </button>
          <p v-if="err('e' + e.key)" :id="errId('e' + e.key)" class="field-error row-wide">{{ err("e" + e.key) }}</p>
        </li>
      </ul>
      <p v-else class="meter-note">Ortam değişkeni yok.</p>
      <button v-if="can('environment')" type="button" class="btn btn-secondary btn-sm fit" data-ekle="e" @click="addEnv"><Icon name="plus" :size="16" />Değişken ekle</button>
      <p class="meter-note">Gizli değerler sunucudan tarayıcıya hiç gelmez; boş bırakılan korunur, satırı silerseniz değişken kalkar.</p>
    </fieldset>

    <fieldset class="form-section">
      <legend class="form-section-title"><Icon name="clock" :size="18" />Komut, başlatma ve sınırlar</legend>
      <Field
        v-slot="{ id, describedby, invalid }"
        label="Çalıştıran hesap"
        hint="Dosyalar hesabıyla sunucu klasörlerindeki dosyalar Dosyalar'la aynı sahipte olur ve yetki yoktur. İmajın kendi hesabı sunucu klasörünü yalnız salt okunur bağlayabilir."
        :error="err('user')"
      >
        <select :id="id" v-model="draft.user" class="input" :disabled="!can('user')" :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-alan="user">
          <option v-for="[value, label] in USERS" :key="value" :value="value">{{ label }}</option>
        </select>
      </Field>
      <Field v-slot="{ id, describedby, invalid }" label="Komut (her satır bir argüman)" hint="Boşsa imajın kendi komutu çalışır." :error="err('command')" optional>
        <textarea :id="id" v-model="draft.command" class="input textarea mono" rows="3" spellcheck="false" :readonly="!can('command')" :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-alan="command"></textarea>
      </Field>
      <label class="check-option check-calm" data-alan="autostart">
        <input v-model="draft.autostart" type="checkbox" :disabled="!can('autostart')" />
        <span>
          <strong>Açılışta başlat</strong>
          <small>Siz durdurursanız bu tercih ne olursa olsun kapalı kalır; Başlat bu durumu kaldırır.</small>
        </span>
      </label>
      <Field v-slot="{ id }" label="Yeniden başlatma">
        <select :id="id" v-model="draft.restart" class="input" :disabled="!can('restart')" data-alan="restart">
          <option v-for="[value, label] in RESTARTS" :key="value" :value="value">{{ label }}</option>
        </select>
      </Field>
      <div class="form-row">
        <Field v-slot="{ id, describedby, invalid }" label="İşlemci sınırı (çekirdek)" :error="err('cpus')" optional>
          <input :id="id" v-model="draft.cpus" class="input mono" type="text" inputmode="decimal" autocomplete="off" placeholder="sınırsız" :readonly="!can('cpus')"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-alan="cpus" />
        </Field>
        <Field v-slot="{ id, describedby, invalid }" label="Bellek sınırı" :error="err('memory')" optional>
          <input :id="id" v-model="draft.memory" class="input mono" type="text" autocomplete="off" placeholder="sınırsız (ör. 512m)" :readonly="!can('memory')"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-alan="memory" />
        </Field>
      </div>
    </fieldset>
  </div>
</template>
