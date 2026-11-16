#!/usr/bin/env python3
"""Loopback-only, synthetic WebDAV directory for simulator integration tests."""
import base64
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.startswith('/unavailable/'):
            self.send_error(503)
            return
        if self.path.startswith('/malformed/'):
            data = b'<html><body>gateway challenge</body></html>'
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path.startswith('/empty/'):
            value = {'comments': [], 'count': 0}
        elif self.path == '/segment-good':
            value = {'comments': [{'p': '1.5,1,16777215,fixture', 'm': 'surviving segment'}]}
        elif self.path == '/segment-bad':
            self.send_error(503)
            return
        elif self.path.startswith('/backup/api/v2/search/anime'):
            value = {'animes': [{'animeId': 123, 'animeTitle': 'Synthetic series', 'episodeCount': 1}], 'success': True}
        elif self.path.startswith('/backup/api/v2/bangumi/123'):
            value = {'bangumi': {'episodes': [{'episodeId': 123001, 'episodeTitle': 'Episode 1'}]}}
        elif self.path.startswith('/backup/api/v2/comment/123001'):
            value = {'comments': [{'p': '1.5,1,16777215,fixture', 'm': 'synthetic comment'}], 'count': 1}
        else:
            self.send_error(404)
            return
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_PROPFIND(self):
        expected = 'Basic ' + base64.b64encode(b'fixture-user:fixture-password').decode()
        if self.headers.get('Authorization') != expected:
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="fixture"')
            self.end_headers()
            return
        self.rfile.read(min(int(self.headers.get('Content-Length', '0')), 65536))
        if self.path == '/dav/':
            href, name, resource = '/dav/Series/', 'Series', '<d:collection/>'
        elif self.path == '/dav/Series/':
            href, name, resource = '/dav/Series/Episode%2001.mkv', 'Episode 01.mkv', ''
        else:
            self.send_error(404)
            return
        xml = f'''<?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:"><d:response><d:href>{href}</d:href>
        <d:propstat><d:prop><d:displayname>{name}</d:displayname>
        <d:resourcetype>{resource}</d:resourcetype><d:getcontentlength>1024</d:getcontentlength>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>'''.encode()
        self.send_response(207)
        self.send_header('Content-Type', 'application/xml; charset=utf-8')
        self.send_header('Content-Length', str(len(xml)))
        self.end_headers()
        self.wfile.write(xml)


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 18765), Fixture).serve_forever()
