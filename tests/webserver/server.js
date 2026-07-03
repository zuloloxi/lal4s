// tests/webserver/server.js — local test server for cf22 CDP web tests.
//
// Pure Node http (no dependencies).  Serves a clean "good" page and a
// deliberately broken "bad" page so the color_iw web primitives can be
// tested against controlled, repeatable content instead of the live
// internet.
//
//   node tests/webserver/server.js [port]        (default 8722)
//
// Routes:
//   /  /good.html   200  clean page — no console errors, no failing requests
//   /bad.html       200  console.error + uncaught throw + 404 img + 500 fetch
//   /api/ok         200  {"ok":true}
//   /api/fail       500  deliberate server error
//   /missing.png    404  (referenced by bad.html to force a network failure)
//   /favicon.ico    204  no content — keeps the GOOD page free of favicon 404s
//   (anything else) 404

const http = require('http');
const PORT = parseInt(process.argv[2], 10) || 8722;

const GOOD = `<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>cf22 Good Page</title></head>
<body>
  <h1 id="main">cf22 test page</h1>
  <button id="go">Go</button>
  <div id="status">ready</div>
  <script>window.cf22Ready = true;</script>  <!-- init completes -->
</body>
</html>`;

// bad.html fires, ON LOAD: a console.error, an uncaught exception, a
// 404 image request, and a 500 fetch.  Tests reload it AFTER connecting
// so these events are captured (CDP only delivers events after the
// domains are enabled).
const BAD = `<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>cf22 Bad Page</title></head>
<body>
  <h1 id="main">broken</h1>
  <img src="/missing.png" alt="">
  <script>
    console.error('cf22 deliberate console error');
    fetch('/api/fail').catch(function(){});
    throw new Error('cf22 deliberate uncaught exception');
    window.cf22Ready = true;   // unreachable: the throw aborts init,
                               // so a "page ready?" health check fails
  </script>
</body>
</html>`;

function send(res, code, type, body) {
  res.writeHead(code, { 'Content-Type': type });
  res.end(body);
}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];
  console.log(new Date().toISOString(), req.method, url);
  switch (url) {
    case '/':
    case '/good.html': return send(res, 200, 'text/html', GOOD);
    case '/bad.html':  return send(res, 200, 'text/html', BAD);
    case '/api/ok':    return send(res, 200, 'application/json', '{"ok":true}');
    case '/api/fail':  return send(res, 500, 'application/json', '{"error":"deliberate"}');
    case '/favicon.ico': res.writeHead(204); return res.end();
    default:           return send(res, 404, 'text/plain', 'not found');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`cf22 test server on http://127.0.0.1:${PORT}/  (good.html / bad.html)`);
  console.log('Ctrl+C to stop.');
});
