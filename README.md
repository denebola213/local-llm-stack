# local-llm-stack

`llama.cpp + Open WebUI` を `podman-compose` で起動するための最小構成です。
`compose.yaml` と `models.ini` を直接参照し、`models.ini` を手で編集して利用モデルを切り替えます。

## 環境変数（.env）

このリポジトリで `.env` から参照している値は現在 `CLOUDFLARE_TUNNEL_TOKEN` のみです。

`.env` 例:

```env
CLOUDFLARE_TUNNEL_TOKEN=REPLACE_WITH_TUNNEL_TOKEN
```

`compose.yaml` の `cloudflared` サービスで `CLOUDFLARE_TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN}` として参照されます。

## 構成

- `llama-server`: `ghcr.io/ggml-org/llama.cpp:server-vulkan`（router mode / 単一コンテナ）
- `open-webui`: `ghcr.io/open-webui/open-webui:main`
- `cloudflared`: Cloudflare Tunnel connector

このホストでは rootless Podman の既定 storage が `overlay on btrfs` で失敗するため、`scripts/compose.sh` はプロジェクトローカルの `vfs` storage を使います。

## 1. モデル指定（models.ini）

`models.ini` を直接編集してモデルを管理します。
`compose.yaml` では `models.ini` を `/models/models.ini` に read-only マウントし、`llama-server --models-preset /models/models.ini` で読み込みます。

`models.ini` 例:

```ini
version = 1

[*]
ctx-size = 32768
n-predict = 1024
threads = 16
parallel = 1
n-gpu-layers = 99
flash-attn = auto
cache-type-k = q8_0
cache-type-v = q8_0
jinja = true
metrics = true

[Qwen3.5-9B]
hf-repo = unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL
load-on-startup = false

[gemma4-26B]
hf-repo = unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q4_K_M
load-on-startup = false
```

初回ロード時はモデルをダウンロードするため時間がかかります。キャッシュは `./data/llama-server/.cache` に保持されます。

## 2. 起動

まず `llama` コマンドを PATH から呼べるように設定します。

### PATH 登録

1. シェル設定ファイルに追記

```bash
echo 'export PATH="./scripts:$PATH"' >> ~/.zshrc
```

1. 設定を反映

```bash
source ~/.zshrc
```

1. 確認

```bash
which llama
llama help
```

### shell 補完

zsh:

```bash
mkdir -p ~/.zfunc
llama completion zsh > ~/.zfunc/_llama
echo 'fpath=(~/.zfunc $fpath)' >> ~/.zshrc
echo 'autoload -Uz compinit && compinit' >> ~/.zshrc
source ~/.zshrc
```

bash:

```bash
mkdir -p ~/.local/share/bash-completion/completions
llama completion bash > ~/.local/share/bash-completion/completions/llama
source ~/.local/share/bash-completion/completions/llama
```

### 基本操作

`models.ini` を編集したら、そのまま起動し直してください。

```bash
llama up
llama logs
llama down
```

主なサブコマンド:

- `llama up` : compose で検出した全サービスを起動（open-webui は最後に `--no-deps` で起動）
- `llama down` : 停止
- `llama logs` : compose で検出した全サービスのログ追従
- `llama ps` : 状態確認
- `llama pull` : イメージ更新
- `llama heal-dns` : DNS 障害時の手動修復
- `llama compose ...` : 低レベル compose コマンドを直接実行

```bash
cd .
./scripts/up.sh
```

`scripts/up.sh` は Podman Compose の依存待機で固まるケースを避けるため、llama サービスを先に起動してから Open WebUI を `--no-deps` で起動します。

- llama.cpp API: `http://127.0.0.1:8080/v1`
- Open WebUI: `http://127.0.0.1:3000`

停止:

```bash
llama down
```

ログ:

```bash
llama logs
```

DNS 修復（障害時のみ）:

```bash
llama down
llama heal-dns
llama up
```

`Cannot connect to host llama-server:8080 ... [Temporary failure in name resolution]` のようなエラーが出た場合にだけ実行してください。通常運用では不要です。

## 3. Open WebUI

Open WebUI は起動時に `llama-server` を OpenAI 互換 API として登録します。

`llama-server` は router mode で動作し、リクエストの `model` フィールドに応じて対象モデルへルーティングします。

`models.ini` で `load-on-startup = false` にしている場合、モデルは必要時にロードされます（初回は待ち時間が発生します）。

## 3.1 Cloudflare Tunnel 経由アクセス

`cloudflared` サービスは `open-webui` をサービス名で参照し、Compose の既定ネットワーク越しに接続します。明示的な `networks` 定義は不要です。

`compose down` 後も接続を維持したい場合は、以下を満たしてください。

- Cloudflare Tunnel の token を `.env` に入れる
- `cloudflared` コンテナを止めない

- `.env` に `CLOUDFLARE_TUNNEL_TOKEN` を設定
- `llama up` 実行
- Cloudflare Zero Trust で tunnel に `open-webui:8080` を向ける published application を作成する

作成後、認証済みクライアントから Open WebUI へ次でアクセスできます。

- tunnel に割り当てた hostname

注意:

- `open-webui` は Compose のサービス名なので、Cloudflare 側の service URL は `http://open-webui:8080` にする
- `cloudflared` は外向き通信だけで動くので、Compose の追加ネットワーク定義は不要

到達しない場合は `cloudflared` コンテナログで tunnel の接続状態を確認してください。

## 4. 調整ポイント

- VRAM 逼迫時は `models.ini` の `ctx-size` を下げる
- 速度を上げたい場合は `models.ini` の `parallel` を 1 にする
- 別モデルに切り替える場合は `models.ini` を変更
- AMD GPU を使わず CPU 動作にしたい場合は `llama.cpp:server` イメージへ変更し、`/dev/dri` を外す
