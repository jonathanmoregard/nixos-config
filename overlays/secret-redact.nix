# `pkgs.secret-redact` — the one place secrets are found and redacted for the
# Claude Code output hooks (~/.claude) and the aggregator's ingest. Both call
# this CLI instead of carrying their own copy of the gitleaks handling.
#
# stdin {"texts": [...], "timeout": s} -> stdout {"texts": [...], "counts": {...}};
# any failure exits non-zero and the caller fails closed. The contract and its
# invariants are in scripts/secret-redact/secret_redact.py.
#
# gitleaks and the rules file are pinned to store paths at build time: no PATH
# lookup and no env var decides what scans the text.
#
# Verified by checks.<system>.secret-redact.
final: prev:
let
  python = "${prev.python3}/bin/python3";
in
{
  secret-redact = prev.runCommand "secret-redact" {
    meta.mainProgram = "secret-redact";
    passthru.gitleaks = prev.gitleaks;
  } ''
    mkdir -p $out/bin $out/lib $out/share/secret-redact
    cp ${../scripts/secret-redact/secret-rules.toml} $out/share/secret-redact/secret-rules.toml
    substitute ${../scripts/secret-redact/secret_redact.py} $out/lib/secret_redact.py \
      --subst-var-by python ${python} \
      --subst-var-by gitleaks ${prev.gitleaks}/bin/gitleaks \
      --subst-var-by rules $out/share/secret-redact/secret-rules.toml
    # Precompiled and checked by hash, not mtime (the store resets mtimes): the
    # hooks run this on every tool result, and compiling it each time cost ~25 ms.
    ${python} -c 'import py_compile, sys; py_compile.compile(sys.argv[1], doraise=True,
      invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH)' $out/lib/secret_redact.py
    printf '#!%s -IS\nimport sys\nsys.path.insert(0, "%s")\nfrom secret_redact import main\nsys.exit(main(sys.argv[1:]))\n' \
      ${python} $out/lib > $out/bin/secret-redact
    chmod +x $out/bin/secret-redact
  '';
}
