# pg_ivm Windows x64 バイナリ利用ガイド

## 1. 対象

pgextwinのpg_ivm packageはWindows x64向けです。

PostgreSQL 14〜18について、それぞれ専用ZIPを作成します。必ず実行対象PostgreSQLの**メジャーバージョンと一致するZIP**を使用してください。

例:

~~~text
pg_ivm-v1.16-pg17-windows-x64.zip
~~~

このZIPはPostgreSQL 17用です。

## 2. ファイル配置

PostgreSQLを停止し、ZIP内のファイルを配置します。

~~~text
ZIP\lib\pg_ivm.dll
  -> <PostgreSQL>\lib\pg_ivm.dll

ZIP\share\extension\pg_ivm.control
ZIP\share\extension\pg_ivm--*.sql
  -> <PostgreSQL>\share\extension\
~~~

## 3. preload

pg_ivmはpreloadした状態で利用してください。

サーバー全体で利用する場合:

~~~conf
shared_preload_libraries = 'pg_ivm'
~~~

すでに他Extensionが設定されている例:

~~~conf
shared_preload_libraries = 'pgaudit,pg_ivm'
~~~

設定変更後はPostgreSQLを再起動します。

session単位でloadする構成では `session_preload_libraries` も利用できます。どちらを選ぶかはupstreamの現在の説明と運用要件に合わせてください。

## 4. Extension作成

対象DBで:

~~~sql
CREATE EXTENSION pg_ivm;
~~~

確認:

~~~sql
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'pg_ivm';
~~~

## 5. 最小動作確認

~~~sql
CREATE TABLE public.ivm_test (
    id integer PRIMARY KEY,
    value integer NOT NULL
);

INSERT INTO public.ivm_test
VALUES (1,10),(2,20),(3,30);

SELECT pgivm.create_immv(
    'public.ivm_test_mv',
    'SELECT id, value FROM public.ivm_test'
);

SELECT * FROM public.ivm_test_mv ORDER BY id;
~~~

次にbase tableを変更します。

~~~sql
INSERT INTO public.ivm_test VALUES (4,40);
UPDATE public.ivm_test SET value = 200 WHERE id = 2;
DELETE FROM public.ivm_test WHERE id = 1;
~~~

再度:

~~~sql
SELECT * FROM public.ivm_test_mv ORDER BY id;
~~~

IMMV側にもINSERT / UPDATE / DELETEが即時反映されていることを確認します。

## 6. 通常のMaterialized Viewとの違い

通常のMaterialized Viewは、base tableが変わっても自動では更新されず、一般に:

~~~sql
REFRESH MATERIALIZED VIEW ...
~~~

が必要です。

pg_ivmのIMMVでは、対応するqueryに対してbase tableの変更差分をtriggerで即時反映します。

ただし、すべてのqueryがIMMV化できるわけではありません。対応構文や制約はupstream READMEを確認してください。

## 7. index

upstreamは、可能な場合 `create_immv` 時にIMMV向けのunique indexを自動作成します。

効率的な増分保守には適切なindexが重要です。自動作成されない場合のNOTICEや、対象queryのkey構成を確認してください。

## 8. pg_dump / pg_upgrade

pg_ivm v1.16のIMMV metadataにはPostgreSQL内部表現が含まれ、major version間でそのまま互換とは限りません。

upstreamはmetadata復元用SQLを生成する `scripts/pg_ivm_dump_metadata` を提供しています。

Windows PowerShellでは同等のSQLを:

~~~powershell
psql.exe -XAtqc "SELECT * FROM pgivm.get_restore_immv_commands()" mydb > immv_restore.sql
~~~

で生成できます。

upgrade/restoreの具体的な順番はupstream v1.16以降の最新READMEに従ってください。

## 9. PostgreSQL 14/15の互換処理

PostgreSQL 14/15のWindows DLL exportモデルはPG16以降と差があります。

pgextwin packageでは、upstream source中の `PG_FUNCTION_INFO_V1(...)` を検出してDEFを生成し、SQL関数本体と `pg_finfo_*` V1 metadata、`Pg_magic_func`、`_PG_init` を明示exportします。

PostgreSQL 14ではさらに、copied backend compatibility codeが参照する2つのdata symbolについて、build workspace内だけで次の置換を行います。

- `InvalidObjectAddress` → `ObjectAddressSet(...)` を使ったローカル値
- `quote_all_identifiers` → `GetConfigOption(...)` を使ったGUC取得

この互換処理はupstream v1.16をforkするものではなく、CIの一時checkoutにだけ適用されます。

## 10. CIでの実動作確認

pgextwinでは各PostgreSQL majorについて:

1. pg_ivm.dllをbuild
2. preload状態でPostgreSQL起動
3. `CREATE EXTENSION pg_ivm`
4. base table作成
5. IMMV作成
6. INSERT
7. UPDATE
8. DELETE
9. IMMVのrow count / 値 / 定義を検証
10. ZIP作成

まで行います。

単なるcompile成功やDLL loadだけでは合格にしません。

## 11. 正規の仕様情報

pgextwinはWindows binaryのbuild・検証・配布を担当します。

以下はupstreamを優先してください。

- IMMVで対応するSELECT構文
- aggregate / DISTINCT / JOIN等の制約
- concurrency
- lock
- transaction isolation
- index要件
- privilege
- dump/restore
- pg_upgrade
- versionごとの仕様変更
