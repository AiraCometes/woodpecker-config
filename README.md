# woodpecker-config

AiraCometes のリポジトリが Woodpecker CI で使う共通の部品。

| ファイル | 使う所 | すること |
| --- | --- | --- |
| `cache.sh` | CI の step | 依存とツールのキャッシュ |
| `notify.sh` | CI の step | 夜の cron が落ちたら、そのリポジトリに Issue を作る |
| `ci-times.sh` | 手元 | パイプラインの段ごとの時間、エージェントを待った時間、その間に流れたほかのリポジトリ |

## cache.sh

キャッシュはエージェントのディスク（`/var/lib/woodpecker-cache`）に置く。書き込めるのは、既定のブランチへの push か、
既定のブランチでの cron が成功したときの `cache-save` の step だけ。どの cron が書くかは、各リポジトリの
`cache-save` の `when`（`cron: nightly`）が決め、`cache.sh` は cron の名前を見ない。ほかの step は読み取り専用でマウントし、
`restore` がパイプラインの `/woodpecker` に写す。写しはパイプラインと一緒に捨てられるので、PR が main のキャッシュを
変えることはできない（キャッシュポイズニングを防ぐ）。

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

`CI_CACHE=off` のときは、復元も保存もしない。古い成果物に頼ったテストの通過を見つけるためである。月に1回の
`cache-cold` の cron は、登録するときに cron の変数で `CI_CACHE=off` を渡す（`cache.sh` は cron の名前を見ない）。各リポジトリの YAML では、流したいワークフローの `when` の `cron:` に `cache-cold` を入れておく（入れないと、どのワークフローも流れない）。

### 使い方

各リポジトリの `.woodpecker/*.yaml` で、コミットの SHA を固定して取得し、sha256 を確かめる。

```yaml
steps:
  - name: restore
    # …
    commands:
      - curl -fsSL https://raw.githubusercontent.com/AiraCometes/woodpecker-config/<SHA>/cache.sh -o /woodpecker/cache.sh
      - echo "<sha256>  /woodpecker/cache.sh" | sha256sum -c
      - bash /woodpecker/cache.sh restore cargo /woodpecker/cargo/registry latest Cargo.lock

  # 最後の step。main への push か、main での nightly の cron が成功したときだけ保存する
  - name: cache-save
    volumes:
      - /var/lib/woodpecker-cache:/cache-rw
    when:
      - event: push
        branch: main
      - event: cron
        cron: nightly
        branch: main
    commands:
      - bash /woodpecker/cache.sh save
```

ほかの step は `/var/lib/woodpecker-cache:/cache:ro` をマウントする。volumes を使うには、リポジトリの設定の
Trusted → Volumes をオンにする。

## notify.sh

夜の cron（`nightly`・`cache-cold`）は PR のチェックに出ないので、落ちても誰かがサーバーを見るまで分からない。
`notify.sh` は、cron のパイプラインでワークフローが落ちたら、そのリポジトリに Issue を作る（GitHub の通知で届く）。
題は「CI: cron のパイプライン #N の fuzz が落ちた」のように、落ちたワークフローの名前を書く。

Woodpecker は step に cron の名前を渡さない。そのため Issue には、パイプラインへのリンク・ブランチ・コミットを書く。
`CI_CACHE=off` のときは、キャッシュを使わない cron（`cache-cold`）だったことも書く。

トークンは、Issues: write だけの fine-grained token を、Woodpecker の secret（`github_issue_token`、イベントは cron と
manual）に入れて渡す。`notify.sh` はトークンをヘッダーのファイルに書いて curl に渡すので、コマンドラインにもログにも
出ない。`GITHUB_TOKEN` が無いときは落ちるので、secret の登録漏れは知らせの step の失敗として見える。

### 使い方

夜に流すワークフローごとに、最後の step として足す。`status: [failure]` の step は、そのワークフローの前の step が
落ちたときだけ流れる。一晩に落ちたワークフローの数だけ Issue ができる。

```yaml
  # 最後の step。cron で、このワークフローが落ちたときだけ Issue を作る
  - name: notify
    image: jdxcode/mise:2026.11.2-debian
    environment:
      GITHUB_TOKEN:
        from_secret: github_issue_token
    when:
      - event: cron
        status: [failure]
    commands:
      - curl -fsSL https://raw.githubusercontent.com/AiraCometes/woodpecker-config/<SHA>/notify.sh -o /tmp/notify.sh
      - echo "<sha256>  /tmp/notify.sh" | sha256sum -c
      - bash /tmp/notify.sh
```

ほかのワークフローを `depends_on` で待ち、`status: [failure]` で流れる知らせのワークフローを1つ置く形は使えない。
Woodpecker（3.20.1 の `server/model/task.go` の `ShouldRun`）は、`status: [failure]` だけのワークフローを、
依存先が1つも成功しなかったときにしか流さない（`gate` が通って `fuzz` だけ落ちた夜は知らせが来ない）。
`[success, failure]` にすれば毎回流れるが、依存先の結果は step に渡らないので、落ちたかどうかが分からない。

この組み方は、このリポジトリの `selftest.yaml` で確かめる。わざと落ちる step のあとの知らせの step が流れ、
このリポジトリに Issue が1つできる（確かめたら閉じる）。

GitHub は手動実行の結果もそのコミットのチェックとして付けるので、PR のブランチで流すと、PR に落ちたチェック
（`ci/woodpecker/manual/selftest`）が残る。確かめたいコミットから別のブランチを作って、そこで流す。

```bash
git push origin HEAD:refs/heads/selftest/notify
cd /tmp && woodpecker-cli pipeline create --branch selftest/notify --var NOTIFY_SELFTEST=1 AiraCometes/woodpecker-config
git push origin --delete selftest/notify  # 確かめたら消す
```

## ci-times.sh

手元で、パイプラインの時間を見る。エージェントはワークフローを1つずつしか流さないので、長い待ちはたいてい、
ほかのリポジトリのパイプラインである。

```bash
./ci-times.sh AiraCometes/kura 15
```

```text
pipeline 15 (pull_request, success): 19m34s from creation to finish
gate  waited 1m11s  ran 2m34s
  clone 3s
  setup 1m0s
  gate 1m28s
  sccache-stats 1s
test  waited 10m12s  ran 5m37s
  ...
other pipelines on the agent meanwhile (13:40:55-13:59:18):
  AiraCometes/curio-media #13 (push) 13:43:30-13:53:40
```

woodpecker-cli は今いるフォルダーの `.env` を読もうとするので、`/tmp` から流す。

## 確かめ方

```bash
shellcheck -S warning cache.sh notify.sh ci-times.sh tests/*.bats
bats tests
```
