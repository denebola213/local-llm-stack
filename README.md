# local-llm-stack

`llama.cpp + Open WebUI` を `podman-compose` で起動するための最小構成です。
この構成は `models` に指定したモデルを必要数だけ同時起動できます。

## 構成

- `llama-server-N`: `ghcr.io/ggml-org/llama.cpp:server-vulkan`（`models` の件数ぶん生成）
- `open-webui`: `ghcr.io/open-webui/open-webui:main`

このホストでは rootless Podman の既定 storage が `overlay on btrfs` で失敗するため、`scripts/compose.sh` は **プロジェクトローカルの `vfs` storage** を使います。

## 1. モデル指定（models）

`.env` の `MODELS_FILE` で指定した INI 形式ファイルを `llama render` が読み取ります。ローカルへの手動配置は不要です。

形式:

- `alias=repo:quant`
- 1行につき1モデル
- `#` または `;` 以降はコメントとして扱います

例:

```env
MODELS_FILE=models
LLAMA_BASE_PORT=8080

HF_TOKEN=your_hf_token_if_needed
```

`models` 例:

```ini
Qwen3.6-35B-A3B=unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M
Qwen3.5-9B=unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL
gemma4-26B=unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q4_K_M
```

各モデルは `--hf-repo` で起動されます。`:<quant>` を省略した場合は llama.cpp 側の既定（通常 `Q4_K_M`）が使われます。

ポートは `LLAMA_BASE_PORT` から順番に割り当てられます。例えば 3 モデルなら `8080`, `8081`, `8082` です。

初回起動時はモデルをダウンロードするため時間がかかります。キャッシュは `./data/llama-server-N/.cache` に保持されます。

別モデルを使う場合は `models` を編集します。

## 2. 起動

まず `llama` コマンドを PATH から呼べるように設定します。

### PATH 登録

1. シェル設定ファイルに追記

```bash
echo 'export PATH="/home/denebola213/Projects/local-llm-stack/scripts:$PATH"' >> ~/.zshrc
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

初回起動時と `models` 編集後は、先に `llama render` を実行してください。

```bash
llama render
llama up
llama logs
llama down
```

主なサブコマンド:

- `llama up` : 既定サービス起動（llama 2系 + open-webui）
- `llama down` : 停止
- `llama logs` : 既定サービスのログ追従
- `llama ps` : 状態確認
- `llama pull` : イメージ更新
- `llama heal-dns` : DNS 障害時の手動修復
- `llama render` : `models` から動的 compose を生成
- `llama compose ...` : 低レベル compose コマンドを直接実行

```bash
cd /home/denebola213/Projects/local-llm-stack
./scripts/up.sh
```

`scripts/up.sh` は Podman Compose の依存待機で固まるケースを避けるため、llama サービスを先に起動してから Open WebUI を `--no-deps` で起動します。

- llama.cpp API: `http://127.0.0.1:${LLAMA_BASE_PORT + i}/v1`（i は 0 始まり）
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

`Cannot connect to host llama-server-N:8080 ... [Temporary failure in name resolution]` のようなエラーが出た場合にだけ実行してください。通常運用では不要です。

## 3. Open WebUI

Open WebUI は起動時に、生成された `llama-server-N` すべてを OpenAI互換API として自動登録します。

## 4. 調整ポイント

- VRAM 逼迫時は `LLAMA_CONTEXT` を下げる
- 速度を上げたい場合は `LLAMA_PARALLEL` を 1 にする
- 別モデルに切り替える場合は `models` を変更
- AMD GPU を使わず CPU 動作にしたい場合は `llama.cpp:server` イメージへ変更し、`/dev/dri` を外す
