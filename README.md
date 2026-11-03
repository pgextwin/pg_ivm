# pg_ivm — Windows x64

[日本語](README_ja.md) | English

pgextwin provides **unofficial Windows x64 binaries** of [pg_ivm](https://github.com/sraoss/pg_ivm). pg_ivm provides incremental view maintenance.

## Download and compatibility

Download the ZIP for your PostgreSQL major from the [latest published Release](https://github.com/pgextwin/pg_ivm/releases/latest) or [all Releases](https://github.com/pgextwin/pg_ivm/releases). Published PostgreSQL **14–18** packages are listed in the [pgextwin catalog](https://pgextwin.github.io/website/en/). PostgreSQL 14 community support ends November 12, 2026. Older files may remain available.

## Installation

1. Back up your installation and review [upstream pg_ivm documentation](https://github.com/sraoss/pg_ivm).
2. Stop PostgreSQL before replacing files. Extract the ZIP matching your PostgreSQL major and copy the included lib/ and share/extension/ contents to the corresponding PostgreSQL directories.
3. Use the loading and initialization method described upstream for your workload; shared or session preloading is supported. Restart PostgreSQL if you changed shared preload settings. Start PostgreSQL after installing the package.
4. Run CREATE EXTENSION pg_ivm; in each database that needs the extension.



Check SHA256SUMS.txt attached to the Release against your downloaded ZIP. Consult the Release for any SPDX SBOM, vulnerability report and signed attestations. Test before production deployment.

## License

The upstream project documents functionality, settings and limitations. This is an independent, unofficial Windows package; see the license notices included in the distribution.
