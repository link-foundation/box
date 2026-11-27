#!/usr/bin/env python3
"""Index the saved template trees and Actions annotations for the issue audit."""

import gzip
import io
from pathlib import Path
import re
from zipfile import ZipFile

EVIDENCE = Path(__file__).resolve().parents[2] / "dev/log/issues/135/pulls/136"
REPOSITORIES = ("box", "js", "rust", "python", "php")
CI_PREFIXES = (".github/", ".githooks/", ".husky/", ".changeset/", "changelog.d/", "scripts/")
ROOT_CONFIGS = {
    ".gitattributes", ".gitignore", ".hadolint.yaml", ".jscpd.json", ".lycheeignore",
    ".nvmrc", ".php-cs-fixer.dist.php", ".pre-commit-config.yaml", ".prettierignore",
    ".prettierrc", ".python-version", ".ruff.toml", ".secretlintrc.json", "Cargo.lock",
    "Cargo.toml", "Dockerfile", "VERSION", "bunfig.toml", "composer.json",
    "composer.lock", "deno.json", "deno.lock", "eslint.config.js", "global.json",
    "lychee.toml", "package-lock.json", "package.json", "phpstan.neon.dist",
    "phpunit.xml.dist", "pyproject.toml", "requirements-dev.in",
    "requirements-dev.txt", "rust-toolchain.toml", "uv.lock",
}


def write_template_index():
    roles = {}
    for repo in REPOSITORIES:
        for name in (EVIDENCE / "github" / f"{repo}.tree").read_text().splitlines():
            if name.startswith(CI_PREFIXES) or name in ROOT_CONFIGS:
                path = Path(name)
                role = path.stem.lower().replace("_", "-")
                if name.startswith(".github/actions/"):
                    role = "/".join(path.parts[2:])
                roles.setdefault((path.parts[0], role), {}).setdefault(repo, []).append(name)

    with (EVIDENCE / "github/ci-role-index.tsv").open("w") as output:
        print("area", "role", *REPOSITORIES, sep="\t", file=output)
        for (area, role), entries in sorted(roles.items()):
            print(area, role, *(", ".join(entries.get(repo, ())) or "-" for repo in REPOSITORIES),
                  sep="\t", file=output)


def write_log_index():
    marker = re.compile(r"Z (?:##\[(?:warning|error|notice)\]|::(?:warning|error|notice)(?=[: ]))")
    with (EVIDENCE / "github/actions-command-census.tsv").open("w") as output:
        print("run", "archive member", "line", "message", sep="\t", file=output)

        def scan(run, member, lines):
            for number, line in enumerate(lines, 1):
                if marker.search(line):
                    print(run, member, number, line.strip().replace("\t", "\\t"),
                          sep="\t", file=output)

        for path in sorted((EVIDENCE / "ci-logs").iterdir()):
            run = path.name.split(".")[0]
            if path.suffix == ".gz":
                with gzip.open(path, "rt", errors="replace") as stream:
                    scan(run, path.name, stream)
            elif path.suffix == ".zip":
                with ZipFile(path) as archive:
                    for member in sorted(archive.namelist()):
                        if re.match(r"^\d+_.+\.txt$", member):
                            with io.TextIOWrapper(archive.open(member), errors="replace") as stream:
                                scan(run, member, stream)


write_template_index()
write_log_index()
