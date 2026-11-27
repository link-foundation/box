## Problem

A Wayback API outage is reported as a missing snapshot. At `e12a25d7`, `WebArchive::snapshot` returns `null` after either multiple unavailable responses or successful responses with an empty snapshot collection. `WebArchive::review` then puts both in `missing`, so the workflow presents the outage as absence of an archive.

## Offline reproduction

Run from the template root.

```bash
php <<'PHP'
<?php
require 'scripts/src/Http.php';
require 'scripts/src/WebArchive.php';
use LinkFoundation\Template\Pipeline\{Http, WebArchive};

$url = 'https://example.com/deleted';
$lookup = static fn ($status, $body) => (new WebArchive(
    new Http(static fn () => ['status' => $status, 'body' => $body]),
    static fn () => null,
))->review([$url]);
$outage = $lookup(503, 'Service unavailable');
$missing = $lookup(200, '{"archived_snapshots":{}}');
var_export([$outage, $missing]);
exit($outage === $missing ? 0 : 1);
PHP
```

## Workaround and code fix

Keep Lychee's verdict and repeat the archive lookup manually after service recovery before discarding a historical reference. Retain bounded retries. Return a result that distinguishes a usable snapshot, a valid empty 200 response, and an unknown outcome when the API gives no valid answer. Add an unknown group to the CLI and describe it separately from missing archives. Use the injected fetcher and sleeper to test a 503 sequence, invalid JSON, a valid empty response, and recovery after an initial request failure.

Found in the audit for link-foundation/box#135.
