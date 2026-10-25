# GKVM Installer V1.0

Public installer for GKVM Panel V1.0.

## Important

The installer does **not** contain the private GKVM Panel source and does **not** ask customers for a GitHub token.

Before publishing, configure `PANEL_DOWNLOAD_URL` in `install.sh` to a server/release URL that serves the private panel artifact (`gkvm-panel.tar.gz`). The download service must keep any GitHub credentials server-side.

License/product-key activation is **not checked before installation**. The installer installs and starts the panel first.

## Run

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mortalgtx01/gkvm-installer/main/install.sh)
```
