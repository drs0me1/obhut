"""The YAML subset reader (rebuild, DD-271 K4): what Compose and Kubernetes files use is read with the
line of every key and item; everything else stops with its line."""
import json
import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
import master_yaml as y  # noqa: E402


def err(text):
    with unittest.TestCase().assertRaises(y.YamlError) as ctx:
        y.load_all(text)
    return ctx.exception


class Scalars(unittest.TestCase):
    def test_core_schema(self):
        doc = y.load("a: 1\nb: -2\nc: 0o17\nd: 0x1f\ne: 1.5\nf: .5\ng: 1e3\nh: true\ni: False\nj: null\n"
                     "k: ~\nl:\nm: yes\nn: on\no: 8080:8080\np: 0755\nq: .inf\nr: -.inf\n")
        self.assertEqual([doc[k] for k in "abcdefgh"], [1, -2, 15, 31, 1.5, 0.5, 1000.0, True])
        self.assertIs(doc["i"], False)
        self.assertIsNone(doc["j"])
        self.assertIsNone(doc["k"])
        self.assertIsNone(doc["l"])
        # YAML 1.2: yes/on are text, 8080:8080 is text (no sexagesimal), 0755 is decimal.
        self.assertEqual((doc["m"], doc["n"], doc["o"], doc["p"]), ("yes", "on", "8080:8080", 755))
        self.assertEqual((doc["q"], doc["r"]), (math.inf, -math.inf))
        self.assertTrue(math.isnan(y.load("x: .nan")["x"]))

    def test_quoted_scalars_are_always_text(self):
        doc = y.load("a: \"1\"\nb: '2'\nc: \"true\"\nd: 'it''s'\ne: \"tab\\there \\u00e7 \\x41 \\\"q\\\" \\\\\"\nf: ''\n")
        self.assertEqual(doc, {"a": "1", "b": "2", "c": "true", "d": "it's", "e": 'tab\there ç A "q" \\', "f": ""})

    def test_comments_and_hashes_inside_values(self):
        doc = y.load("# head\na: b # tail\nc: x#y\nd: \"p # q\"\ne: http://h:8080/#frag\n  # indented comment\n")
        self.assertEqual(doc, {"a": "b", "c": "x#y", "d": "p # q", "e": "http://h:8080/#frag"})

    def test_keys_stay_the_written_text(self):
        doc = y.load("80: a\ntrue: b\n\"8080\": c\nnull: d\n")
        self.assertEqual(list(doc), ["80", "true", "8080", "null"])


class Blocks(unittest.TestCase):
    def test_nested_mappings_and_sequences_with_lines(self):
        text = ("services:\n"
                "  web:\n"
                "    image: nginx:1.27\n"
                "    ports:\n"
                "      - \"8080:80\"\n"
                "      - 443:443\n"
                "    environment:\n"
                "      TZ: Europe/Istanbul\n")
        doc = y.load(text)
        self.assertIsInstance(doc, y.Map)
        web = doc["services"]["web"]
        self.assertEqual(web["ports"], ["8080:80", "443:443"])
        self.assertEqual(web.key_lines, {"image": 3, "ports": 4, "environment": 7})
        self.assertEqual(web["ports"].item_lines, [5, 6])
        self.assertEqual(web["ports"].line, 5)
        self.assertEqual(doc["services"].line, 2)

    def test_sequence_at_its_keys_indentation(self):
        # podman kube generate writes sequences at the key's own indentation.
        text = ("spec:\n"
                "  containers:\n"
                "  - args:\n"
                "    - serve\n"
                "    image: docker.io/library/redis:7\n"
                "    name: redis\n"
                "  - image: b\n"
                "  restartPolicy: Always\n")
        spec = y.load(text)["spec"]
        self.assertEqual(spec["containers"][0], {"args": ["serve"], "image": "docker.io/library/redis:7", "name": "redis"})
        self.assertEqual(spec["containers"][1], {"image": "b"})
        self.assertEqual(spec["restartPolicy"], "Always")
        self.assertEqual(spec["containers"].item_lines, [3, 7])
        self.assertEqual(spec["containers"][0].key_lines["image"], 5)

    def test_items_holding_mappings_sequences_and_nothing(self):
        doc = y.load("- a: 1\n  b: 2\n- - x\n  - y\n-\n-   c: 3\n    d: 4\n- 'q'\n")
        self.assertEqual(doc, [{"a": 1, "b": 2}, ["x", "y"], None, {"c": 3, "d": 4}, "q"])

    def test_empty_values_and_documents(self):
        self.assertEqual(y.load("a:\nb:\n  c:\n"), {"a": None, "b": {"c": None}})
        self.assertEqual(y.load_all(""), [])
        self.assertEqual(y.load_all("# only a comment\n"), [])
        self.assertEqual(y.load_all("---\n"), [None])

    def test_several_documents(self):
        docs = y.load_all("---\nkind: Pod\n---\nkind: PersistentVolumeClaim\n...\n# gap\n---\na: 1\n")
        self.assertEqual(docs, [{"kind": "Pod"}, {"kind": "PersistentVolumeClaim"}, {"a": 1}])
        self.assertEqual(y.load_all("a: 1\n---\nb: 2\n")[1].key_lines, {"b": 3})

    def test_crlf_and_bom(self):
        self.assertEqual(y.load("\ufeffa: 1\r\nb:\r\n  - x\r\n"), {"a": 1, "b": ["x"]})


class BlockScalars(unittest.TestCase):
    def test_literal_chomping(self):
        doc = y.load("a: |\n  one\n  two\n\nb: |-\n  one\nc: |+\n  one\n\n\nd: x\n")
        self.assertEqual(doc["a"], "one\ntwo\n")
        self.assertEqual(doc["b"], "one")
        self.assertEqual(doc["c"], "one\n\n\n")
        self.assertEqual(doc["d"], "x")

    def test_literal_keeps_inner_indentation_and_hashes(self):
        doc = y.load("cmd: |\n  if true; then\n    echo # not a comment\n  fi\nnext: 1\n")
        self.assertEqual(doc["cmd"], "if true; then\n  echo # not a comment\nfi\n")

    def test_folded(self):
        doc = y.load("a: >\n  one\n  two\n\n  three\n    kept\n  four\nb: >-\n  x\n  y\n")
        self.assertEqual(doc["a"], "one two\nthree\n  kept\nfour\n")
        self.assertEqual(doc["b"], "x y")

    def test_explicit_indentation_and_item_scalars(self):
        doc = y.load("a: |2\n    deeper\n  base\nb:\n  - |\n    in item\n  - >-\n    folded item\n")
        self.assertEqual(doc["a"], "  deeper\nbase\n")
        self.assertEqual(doc["b"], ["in item\n", "folded item"])

    def test_empty_block_scalar(self):
        self.assertEqual(y.load("a: |\nb: 1\n"), {"a": "", "b": 1})


class Flow(unittest.TestCase):
    def test_flow_collections(self):
        doc = y.load('test: ["CMD", "wget", "-qO-", "http://localhost:8080/health"]\n'
                     "ports: { web: 8080, \"raw\": [6881, 6882], empty: , url: http://x:1/y }\n"
                     "none: []\nnothing: {}\n")
        self.assertEqual(doc["test"], ["CMD", "wget", "-qO-", "http://localhost:8080/health"])
        self.assertEqual(doc["ports"], {"web": 8080, "raw": [6881, 6882], "empty": None, "url": "http://x:1/y"})
        self.assertEqual((doc["none"], doc["nothing"]), ([], {}))

    def test_flow_over_several_lines_with_comments_and_trailing_commas(self):
        doc = y.load("args: [\n  a,   # first\n  'b c',\n  {k: v},\n]\nafter: 1\n")
        self.assertEqual(doc["args"], ["a", "b c", {"k": "v"}])
        self.assertEqual(doc["args"].item_lines, [2, 3, 4])
        self.assertEqual(doc["after"], 1)

    def test_plain_flow_text_with_spaces_and_shell(self):
        doc = y.load("test: [CMD-SHELL, curl -f http://localhost:8080 || exit 1]\n")
        self.assertEqual(doc["test"], ["CMD-SHELL", "curl -f http://localhost:8080 || exit 1"])


class Refusals(unittest.TestCase):
    def check(self, text, line, words):
        e = err(text)
        self.assertEqual(e.line, line, (text, str(e)))
        self.assertIn(words, str(e))
        return e

    def test_anchors_aliases_merge_and_tags(self):
        self.check("a: &x 1\n", 1, "Çapa")
        self.check("a: 1\nb: *x\n", 2, "Takma ad")
        self.check("base:\n  a: 1\nweb:\n  <<: 1\n", 4, "Birleştirme")
        self.check("a: !!str 1\n", 1, "Etiket")
        self.check("- !custom x\n", 1, "Etiket")
        self.check("a: [&x 1]\n", 1, "Çapa")

    def test_complex_keys_directives_and_document_content(self):
        self.check("? a\n: b\n", 1, "Karmaşık anahtar")
        self.check("%YAML 1.2\n---\na: 1\n", 1, "yönergesi")
        self.check("--- a: 1\n", 1, "Belge ayırıcısından")
        self.check("a: 1\n...\nb: 2\n", 3, "Belge sonundan")
        self.check("a: {[x]: 1}\n", 1, "Karmaşık anahtar")

    def test_duplicates_tabs_and_indentation(self):
        self.check("a: 1\nb: 2\na: 3\n", 3, "Aynı anahtar")
        self.check("a: {x: 1, x: 2}\n", 1, "Aynı anahtar")
        self.check("a:\n\tb: 1\n", 2, "sekme")
        self.check("a:\n  b: 1\n    c: 2\n", 3, "Çok satırlı")
        self.check("a:\n  b:\n    c: 1\n   d: 2\n", 4, "Beklenmeyen girinti")
        self.check("a: 1\n- b\n", 2, "Liste öğesi")
        self.check("a: 1\nplain\n", 2, "Eşleme anahtarı")

    def test_multi_line_scalars(self):
        self.check("a: one\n  two\n", 2, "Çok satırlı")
        self.check('a: "one\n  two"\n', 1, "Tırnak kapanmamış")
        self.check("- one\n  two\n", 2, "Çok satırlı")
        self.check("a: b: c\n", 1, "iç içe eşleme")

    def test_flow_errors(self):
        self.check("a: [1, 2\nb: 3\n", 2, "Liste içinde , ya da ] bekleniyordu")
        self.check("a: [1, 2\n", 2, "Kapanmamış")
        self.check("a: [x: 1]\n", 1, "Liste içinde eşleme")
        self.check("a: [1 2] tail\n", 1, "Beklenmeyen içerik")
        self.check('a: "bad \\q"\n', 1, "Geçersiz kaçış")

    def test_limits(self):
        e = err("a: " + "x" * (y.LIMIT_BYTES + 1))
        self.assertIn("çok büyük", str(e))
        deep = "".join(" " * (2 * n) + "k:\n" for n in range(y.MAX_DEPTH + 2))
        self.assertIn("derin", str(err(deep)))
        self.assertIn("NUL", str(err("a: 1\nb: \x00\n")))
        with self.assertRaises(y.YamlError):
            y.load("a: 1\n---\nb: 2\n")

    def test_the_error_carries_a_column(self):
        e = err("a:\n  b: *ref\n")
        self.assertEqual((e.line, e.column), (2, 6))


class RealFiles(unittest.TestCase):
    def test_linuxserver_style_compose(self):
        text = ("---\nservices:\n  qbittorrent:\n    image: lscr.io/linuxserver/qbittorrent:latest\n"
                "    container_name: qbittorrent\n    environment:\n      - PUID=1000\n      - PGID=1000\n"
                "      - TZ=Etc/UTC\n      - WEBUI_PORT=8080\n    volumes:\n      - /path/to/qbittorrent/appdata:/config\n"
                "      - /path/to/downloads:/downloads #optional\n    ports:\n      - 8080:8080\n      - 6881:6881\n"
                "      - 6881:6881/udp\n    restart: unless-stopped\n")
        s = y.load(text)["services"]["qbittorrent"]
        self.assertEqual(s["ports"], ["8080:8080", "6881:6881", "6881:6881/udp"])
        self.assertEqual(s["volumes"][1], "/path/to/downloads:/downloads")
        self.assertEqual(s["environment"][0], "PUID=1000")
        self.assertEqual(s.key_lines["restart"], 18)

    def test_kube_generate_style_pod(self):
        text = ("# Save the output of this file and use kubectl create -f to import\n"
                "apiVersion: v1\nkind: Pod\nmetadata:\n  annotations:\n    io.kubernetes.cri-o.SandboxID/redis: abc\n"
                "  creationTimestamp: \"2026-10-17T00:00:00Z\"\n  labels:\n    app: test-redis\n  name: test-redis\n"
                "spec:\n  containers:\n  - args:\n    - redis-server\n    image: docker.io/library/redis:7\n    name: redis\n"
                "    ports:\n    - containerPort: 6379\n      hostPort: 6379\n    securityContext: {}\n"
                "    volumeMounts:\n    - mountPath: /data\n      name: veri-pvc\n  volumes:\n  - name: veri-pvc\n"
                "    persistentVolumeClaim:\n      claimName: veri\n")
        pod = y.load(text)
        c = pod["spec"]["containers"][0]
        self.assertEqual(c["ports"], [{"containerPort": 6379, "hostPort": 6379}])
        self.assertEqual(c["securityContext"], {})
        self.assertEqual(pod["spec"]["volumes"][0]["persistentVolumeClaim"], {"claimName": "veri"})
        self.assertEqual(pod["metadata"]["creationTimestamp"], "2026-10-17T00:00:00Z")
        self.assertEqual(c["ports"].item_lines, [18])

    def test_results_serialise_as_plain_json(self):
        doc = y.load("a:\n  - {b: 1}\n")
        self.assertEqual(json.loads(json.dumps(doc)), {"a": [{"b": 1}]})


if __name__ == "__main__":
    unittest.main()
