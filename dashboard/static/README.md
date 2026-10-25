# Vendored front-end script

`htmx.min.js` is htmx **2.0.4** (`dist/htmx.min.js` from the `htmx.org` npm package), licence 0BSD.
It is served by the dashboard itself so the admin page loads no third-party script.

- sha256: `e209dda5c8235479` (first 16 hex characters; the file is byte-identical to the one in the npm tarball)
- sha384 (for an SRI attribute): `HGfztofotfshcF7+8n44JQL2oJmowVChPTg48S+jvZoztPfvwD79OC/LTtG6dMp+`

To update: download the new `dist/htmx.min.js` from the npm tarball, replace the file, and update this note and the version in `templates/index.html`.

# App icons

`icons/` holds each app's own icon so the dashboard tiles match the apps. They are copied from the running images and are the vendors' trademarks, used here only to label links to those apps in this private stack.

| File | Source |
|---|---|
| `openclaw.svg` | OpenClaw Control UI `favicon.svg` (animated) |
| `litellm.svg` | `litellm_monogram_dark.svg` from the LiteLLM image |
| `grafana.svg` | `public/img/grafana_icon.svg` from the `grafana/grafana` image (the stack mounts a GB10 icon over it at runtime) |
| `portainer.png` | `apple-touch-icon` (180 px) from the Portainer image |
| `comfyui.png` | 48 px entry of ComfyUI's `favicon.ico` |
| `terminal.svg` | drawn for this stack (terminal window with a `>_` prompt, off-white on near-black); not a vendor logo |
| `minio.png` | 96 px favicon of the MinIO console (served at `/s3/favicon-96x96.png`) |
| `jupyter.png` | 64 px entry of Jupyter's `favicon.ico` (served at `/jupyter/static/favicon.ico`) |
