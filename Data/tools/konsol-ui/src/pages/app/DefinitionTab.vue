<!-- An application's Tanım (DD-271, phase 3; K3), read-only: where its file came from, the file exactly as
     given, the operator's answers (a secret answer only says that a value is set), its secrets by name with
     the services that use them (no value ever reaches the browser) and the units Obhut wrote from them. -->
<script setup lang="ts">
import { computed } from "vue";
import Card from "../../components/ui/Card.vue";
import CopyButton from "../../components/ui/CopyButton.vue";
import { Icon } from "../../components/icons";
import { SOURCE_TEXT, START_TEXT } from "../../apps";
import { dateTime } from "../../format";
import type { Yanit, YanitSakli, UygulamaAyrinti } from "../../api/sema";

const props = defineProps<{ detail: UygulamaAyrinti }>();

const source = computed(() => props.detail.koken);

/** An answer in words; a secret one never carries its value. */
function answerText(a: Yanit | YanitSakli): { text: string; mono: boolean; secret: boolean } {
  if ("set" in a) return { text: "gizli · gösterilmez", mono: false, secret: true };
  if ("use" in a) {
    if (a.use === "raw") return { text: "Ham port", mono: false, secret: false };
    return { text: a.tailscale_name ? `Adres · Tailscale adı ${a.tailscale_name}` : "Adres", mono: false, secret: false };
  }
  if ("value" in a) return { text: a.value, mono: true, secret: false };
  if ("mode" in a) return { text: START_TEXT[a.mode] ?? a.mode, mono: false, secret: false };
  if (a.to === "srv") return { text: `${a.path}${a.read_only ? " · salt okunur" : ""}`, mono: true, secret: false };
  return { text: "Uygulamanın klasörü", mono: false, secret: false };
}

const answers = computed(() =>
  Object.entries(props.detail.yanitlar.answers)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([id, a]) => ({ id, ...answerText(a) })),
);
</script>

<template>
  <div class="definition-tab">
    <p class="meter-note">Tanım burada salt okunur; değiştirmek Konsol'un yeni ekranlarıyla gelecek.</p>
    <div class="tab-grid tab-grid-wide">
      <Card title="Kaynak" data-testid="source">
        <dl class="facts">
          <dt>Nereden</dt>
          <dd data-testid="source-kind">{{ SOURCE_TEXT[source.tur] ?? source.tur }}</dd>
          <template v-if="source.adres">
            <dt>Adres</dt>
            <dd class="mono wrap">{{ source.adres }}</dd>
          </template>
          <template v-if="source.imaj">
            <dt>İmaj</dt>
            <dd class="mono wrap">{{ source.imaj }}</dd>
          </template>
          <template v-if="source.konteyner">
            <dt>Konteyner</dt>
            <dd class="mono wrap">{{ source.konteyner }}</dd>
          </template>
          <dt>Alındı</dt>
          <dd>{{ dateTime(source.alindi) }}</dd>
          <dt>SHA-256</dt>
          <dd class="mono wrap" data-testid="source-sha">{{ source.sha256 }}</dd>
        </dl>
      </Card>

      <Card title="Gizli değerler" data-testid="secrets">
        <ul v-if="detail.gizliler.length" class="mount-list">
          <li v-for="g in detail.gizliler" :key="g.ad" class="mount" :data-gizli="g.ad">
            <span class="mono">{{ g.ad }}</span>
            <span class="mount-meta">{{ g.servisler.join(", ") }}</span>
          </li>
        </ul>
        <p v-else class="meter-note">Gizli değer yok.</p>
        <p class="meter-note secret-note"><Icon name="lock" :size="14" />Değerler sunucuda saklanır; tarayıcıya hiç gönderilmez.</p>
      </Card>

      <Card title="Yanıtlar" data-testid="answers">
        <dl v-if="answers.length" class="facts answer-facts">
          <template v-for="a in answers" :key="a.id">
            <dt class="mono wrap">{{ a.id }}</dt>
            <dd :class="{ mono: a.mono, wrap: true, muted: a.secret }" :data-yanit="a.id">{{ a.text }}</dd>
          </template>
        </dl>
        <p v-else class="meter-note">Yanıt yok.</p>
      </Card>

      <Card title="Birimler" data-testid="units">
        <ul class="mount-list">
          <li v-for="u in detail.birimler" :key="u" class="mount mono">{{ u }}</li>
        </ul>
      </Card>
    </div>

    <section class="card raw-file" aria-label="Dosya" data-testid="file">
      <div class="raw-head">
        <h2 class="card-title">Dosya</h2>
        <CopyButton :text="detail.metin" label="Dosya" />
      </div>
      <pre class="log raw-text" tabindex="0" aria-label="Dosyanın içeriği">{{ detail.metin }}</pre>
    </section>
  </div>
</template>
