// Tiny static server for the embed-contract tests. Mimics GitHub Pages'
// clean-URL behaviour: /embed resolves to embed/index.html (the seamless
// loader builds exactly that extensionless URL).
//   node tests/embed-contract/server.mjs <port> <rootDir>
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, extname, normalize } from 'node:path';

const [port, root] = [Number(process.argv[2]), process.argv[3]];
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.png': 'image/png', '.json': 'application/json', '.xml': 'application/xml', '.txt': 'text/plain' };

createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x');
    let path = normalize(url.pathname).replace(/^([/\\])+/, '');
    if (path.includes('..')) { res.writeHead(400); res.end(); return; }
    if (path === '' || path.endsWith('/')) path += 'index.html';
    let file;
    try {
      file = await readFile(join(root, path));
    } catch {
      // clean URL: /embed -> embed/index.html
      file = await readFile(join(root, path, 'index.html'));
      res.setHeader('content-type', 'text/html');
      res.writeHead(200); res.end(file); return;
    }
    res.setHeader('content-type', MIME[extname(path)] || 'application/octet-stream');
    res.writeHead(200); res.end(file);
  } catch {
    res.writeHead(404); res.end('not found');
  }
}).listen(port, () => console.log(`serving ${root} on :${port}`));
