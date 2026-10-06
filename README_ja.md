# pg_ivm Windows バイナリ

[English](README.md) | **日本語**

このリポジトリでは、PostgreSQLのIncremental View Maintenance（増分ビュー保守）Extensionである [pg_ivm](https://github.com/sraoss/pg_ivm) の **非公式 Windows x64 バイナリ**を提供します。

upstream `sraoss/pg_ivm` の `v1.16` を固定し、通常のWindows版PostgreSQL環境で検証します。

## 対応範囲

upstream v1.16はPostgreSQL 13〜18対応を表明しています。

pgextwinでは、現在PostgreSQLコミュニティのメンテナンス対象であるPostgreSQL 14〜18を配布対象とします。

初回Release tagは次を予定しています。

~~~text
v1.16-windows.1
~~~

ZIP名:

~~~text
pg_ivm-v1.16-pg14-windows-x64.zip
...
pg_ivm-v1.16-pg18-windows-x64.zip
~~~

## pg_ivmの概要

pg_ivmは、通常の `REFRESH MATERIALIZED VIEW` のように毎回全体を再計算するのではなく、base tableの変更分をIMMV（Incrementally Maintainable Materialized View）へ即時反映します。

例:

~~~sql
CREATE EXTENSION pg_ivm;

CREATE TABLE t (
    id integer PRIMARY KEY,
    payload integer NOT NULL
);

INSERT INTO t VALUES (1, 10), (2, 20);

SELECT pgivm.create_immv(
    'public.t_immv',
    'SELECT id, payload FROM public.t'
);
~~~

この後、`t` に対するINSERT / UPDATE / DELETEは、同じtransaction内で `t_immv` に増分反映されます。

対応するSELECT構文、制限、lock・並行処理、運用上の注意はupstreamドキュメントを正規の情報源としてください。

## 導入

1. PostgreSQLの**メジャーバージョンに一致するZIP**を選びます。
2. PostgreSQLを停止します。
3. `lib/pg_ivm.dll` をPostgreSQLの `lib` にコピーします。
4. `share/extension/*` をPostgreSQLの `share/extension` にコピーします。
5. preload設定を行います。
6. `shared_preload_libraries` を使う場合はPostgreSQLを再起動します。
7. 利用するDBで次を実行します。

~~~sql
CREATE EXTENSION pg_ivm;
~~~

## preload設定

upstreamは、正しいIMMV保守のため、pg_ivmを次のどちらかでloadするよう案内しています。

~~~conf
shared_preload_libraries = 'pg_ivm'
~~~

または:

~~~conf
session_preload_libraries = 'pg_ivm'
~~~

Windowsサーバーへ通常導入する場合は、`shared_preload_libraries` の方が管理しやすいケースが多いです。

すでに別Extensionをpreloadしている場合は、既存値を消さずカンマ区切りで追加してください。

## Windows build

pg_ivm v1.16にはupstream自身のMSVC対応Meson buildが存在します。

pgextwinではforkしたWindows用sourceを維持せず、原則としてこのupstream build経路をそのまま利用します。

CIでは:

1. upstream `v1.16` を固定
2. upstream LICENSEを完全一致で検証
3. Meson/Ninjaを固定versionで用意
4. MSVC x64環境を初期化
5. 対象PostgreSQLの `bin` をPATHへ追加
6. upstream `meson.build` で `pg_ivm.dll` をbuild

という構成です。

過去にWindowsでfunction linkage不整合がupstream issue #138として報告されましたが、commit `49b52bcd5ec96c2c496212e4a9cd11b023dad0a9` で必要な `PGDLLEXPORT` が追加されており、v1.16にはこの修正が含まれています。

### PostgreSQL 14/15のWindows互換処理

PG14〜18へ対象を広げたpilotでは、標準Windows版PostgreSQLの旧世代に追加差分があることを確認しました。

PostgreSQL 14/15では、新しい世代と異なり `PG_FUNCTION_INFO_V1(...)` によるSQL関数群が必要な形ですべて自動exportされません。そのためpgextwinはpinned upstream sourceからDEFを生成し、次を明示exportします。

- `Pg_magic_func`
- `_PG_init`
- `PG_FUNCTION_INFO_V1(...)` で宣言された全SQL関数
- 対応する `pg_finfo_<function>` V1 ABI metadata関数

PG16〜18でも同じ明示export一覧を利用し、CIで `dumpbin /exports` による検証を行います。

PostgreSQL 14ではさらに、pg_ivmが内包するPG14互換コードから `InvalidObjectAddress` と `quote_all_identifiers` というbackend data symbolを参照しますが、通常のEDB Windows配布の `postgres.lib` ではこの経路をそのままlinkできません。

PG14だけbuild用の一時checkoutに対して:

- `InvalidObjectAddress` をimportせず `ObjectAddressSet(...)` で同値の無効ObjectAddressをローカル生成
- `quote_all_identifiers` data variableをimportせず、export済みの `GetConfigOption(...)` で同じGUC値を取得

という置換を行います。

PostgreSQL本体を置換・再buildする必要はなく、不透明な互換objectもrepositoryには保存しません。

## CIの合格条件

対応する各PostgreSQL majorで次まで確認します。

- upstream LICENSEの一致
- upstream Meson/MSVCによるWindows x64 build
- pg_ivm.dllの配置
- pg_ivmをpreloadしたPostgreSQLの起動
- `CREATE EXTENSION pg_ivm`
- primary key付きbase table作成
- `pgivm.create_immv(...)` によるIMMV作成
- INSERTの即時反映
- UPDATEの即時反映
- DELETEの即時反映
- `pgivm.get_immv_def(...)` の確認
- Windows x64 ZIP生成

## pg_dump / pg_upgrade時の注意

pg_ivm v1.16では、IMMV定義に関する内部query metadataがPostgreSQL versionに依存します。

upstreamは `scripts/pg_ivm_dump_metadata` を提供し、`pgivm.restore_immv()` を呼び出すSQLを生成する手順を案内しています。

Windowsでは、同等のSQLを次のように生成できます。

~~~powershell
psql.exe -XAtqc "SELECT * FROM pgivm.get_restore_immv_commands()" mydb > immv_restore.sql
~~~

`pg_dump` や `pg_upgrade` の前後では、その時点のupstream READMEに記載された手順を必ず確認してください。

IMMVのmetadata tableをPostgreSQL major間でそのままportableなapplication dataとして扱わないでください。

## ライセンス

このrepositoryの `LICENSE` はupstream v1.16のLICENSEと同一です。Release ZIPにもbuildに使用したupstream checkoutからLICENSEを直接同梱します。

本バイナリはpgextwinによる非公式配布であり、pg_ivm upstreamまたはPostgreSQLプロジェクトによる公式Windows binaryではありません。
