// WIN ZONE — Zero-dependency Local Live Preview Server
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 3000;

const MIME_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.json': 'application/json',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon'
};

const server = http.createServer((req, res) => {
    // Basic CORS & headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');

    const parsedUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    let pathname = decodeURIComponent(parsedUrl.pathname);

    if (pathname === '/') {
        pathname = '/index.html';
    }

    let filePath = path.join(__dirname, pathname);

    // If path is a file that exists
    if (!fs.existsSync(filePath)) {
        // Try appending .html
        if (fs.existsSync(filePath + '.html')) {
            filePath = filePath + '.html';
        } else {
            res.writeHead(404, { 'Content-Type': 'text/plain' });
            res.end('404 Not Found: ' + pathname);
            return;
        }
    }

    // If directory, look for index.html
    const stat = fs.statSync(filePath);
    if (stat.isDirectory()) {
        filePath = path.join(filePath, 'index.html');
        if (!fs.existsSync(filePath)) {
            res.writeHead(404, { 'Content-Type': 'text/plain' });
            res.end('404 Directory Index Not Found');
            return;
        }
    }

    const ext = path.extname(filePath).toLowerCase();
    const contentType = MIME_TYPES[ext] || 'application/octet-stream';

    fs.readFile(filePath, (err, data) => {
        if (err) {
            res.writeHead(500, { 'Content-Type': 'text/plain' });
            res.end('500 Server Error: ' + err.message);
            return;
        }
        res.writeHead(200, { 'Content-Type': contentType });
        res.end(data);
    });
});

server.listen(PORT, () => {
    console.log(`WIN ZONE Live Preview Server running at http://localhost:${PORT}`);
});
