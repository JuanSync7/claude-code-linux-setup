# publish/ — what the public template edition adds

*Map of this directory. The procedure is [`docs/PUBLISHING.md`](../docs/PUBLISHING.md).*

| Path | What it is |
| --- | --- |
| `overlay/` | Files `bin/cc-publish.sh` lays over the exported tree, at the same relative path: `template.json` (the placeholder list CI and `bin/cc-template-fill.sh` read), `TEMPLATE.md` (how to fill it) and `LICENSE` (MIT) at the root; the blank registers that replace this site's `internal/`; and `docs/SANDBOX-DECISION.md`, a generic record that replaces this site's own, whose investigation belongs to one site |

The overlay files carry no relative links: they are tracked here and read at a different
depth once published, so a link could only be right in one of the two places.
