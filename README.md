# woodpecker-config

AiraCometes のリポジトリが Woodpecker CI で使う共通の部品。今は依存とツールのキャッシュ（`cache.sh`）だけ。

## cache.sh

キャッシュはエージェントのディスク（`/var/lib/woodpecker-cache`）に置く。書き込めるのは、既定のブランチへの push が
成功したときの `cache-save` の step だけ。ほかの step は読み取り専用でマウントし、`restore` がパイプラインの
`/woodpecker` に写す。写しはパイプラインと一緒に捨てられるので、PR が main のキャッシュを変えることはできない
（キャッシュポイズニングを防ぐ）。

| MODE | 使うもの | 例 |
| --- | --- | --- |
| `exact` | キーが一致するものだけ。無ければ空から | mise・rustup のツール（mise.toml・版・イメージのタグがキー） |
| `latest` | 一致するもの、無ければ同じ名前の最新。ダウンロードはロックファイルで確かめられるもの | cargo の registry（Cargo.lock）、npm・uv |
| `rolling` | 同じ名前の最新。save は毎回新しく保存する | sccache（ワークフローごと） |

キーは、名前と INPUT（ファイルの中身の sha256、または `=文字列`）の sha256。ロックファイルや版が変われば別のキーになり、
`exact` は空から作り直す。置き場は `v1/<owner__repo>/<名前>/<uname -m>/<キー>/`で、リポジトリと CPU ごとに分かれる。

保存のあと、次の順で古いものを消す（環境変数で変えられる）。

1. 名前ごとに新しい `CACHE_KEEP`（2）個だけ残す
2. `CACHE_MAX_AGE_DAYS`（30）日、保存も利用もされなかったもの
3. sccache の合計が `CACHE_SCCACHE_MAX_GB`（20）を超えた分、全体が `CACHE_MAX_GB`（50）を超えた分と、
   空きが `CACHE_MIN_FREE_GB`（30）を下回った分を、古い順に

`CI_CACHE=off` か、cron のジョブ名 `cache-cold`（月に1回）のときは、復元も保存もしない。古い成果物に頼った
テストの通過を見つけるため。

### 使い方

各リポジトリの `.woodpecker/*.yaml` で、コミットの SHA を固定して取得し、sha256 を確かめる。

```yaml
- curl -fsSL https://raw.githubusercontent.com/AiraCometes/woodpecker-config/<SHA>/cache.sh -o /woodpecker/cache.sh
- echo "<sha256>  /woodpecker/cache.sh" | sha256sum -c
- bash /woodpecker/cache.sh restore cargo /woodpecker/cargo/registry latest Cargo.lock
# …
# 最後の step（when: push の main で、成功したとき。volumes は /var/lib/woodpecker-cache:/cache-rw）
- bash /woodpecker/cache.sh save
```

ほかの step は `/var/lib/woodpecker-cache:/cache:ro` をマウントする。volumes を使うには、リポジトリの設定の
Trusted → Volumes をオンにする。

## 確かめ方

```bash
shellcheck -S warning cache.sh tests/cache.bats
bats tests
```
