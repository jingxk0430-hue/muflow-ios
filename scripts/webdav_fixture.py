#!/usr/bin/env python3
"""Loopback-only, synthetic WebDAV directory for simulator integration tests."""
import base64
import json
import hashlib
import urllib.parse
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/bili-comments':
            xml = b'<i><d p="1.25,1,25,65280,0,0,0,0">deflated fixture</d></i>'
            compressor = zlib.compressobj(wbits=-15)
            data = compressor.compress(xml) + compressor.flush()
            self.send_response(200)
            self.send_header('Content-Type', 'text/xml')
            self.send_header('Content-Encoding', 'deflate')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path.startswith('/youku/'):
            self.send_response(200)
            if self.path.startswith('/youku/meta'):
                value = {'duration': 61, 'title': 'Synthetic video'}
            elif self.path.startswith('/youku/visitor'):
                self.send_header('Set-Cookie', 'cna=fixture-visitor; Path=/; HttpOnly')
                value = {}
            elif self.path.startswith('/youku/session'):
                self.send_header('Set-Cookie', '_m_h5_tk=0123456789abcdef0123456789abcdef_9999999999999; Path=/; HttpOnly')
                self.send_header('Set-Cookie', '_m_h5_tk_enc=fixture-encrypted; Path=/; HttpOnly')
                value = {}
            else:
                value = {}
            data = json.dumps(value).encode()
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
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

    def do_POST(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path != '/youku/comments':
            self.send_error(404)
            return
        body = self.rfile.read(min(int(self.headers.get('Content-Length', '0')), 65536))
        try:
            raw = urllib.parse.parse_qs(body.decode())['data'][0]
            wrapper = json.loads(raw)
            message = json.loads(base64.b64decode(wrapper['msg']))
            query = urllib.parse.parse_qs(url.query)
            expected = hashlib.md5(('0123456789abcdef0123456789abcdef&'+query['t'][0]+'&24679788&'+raw).encode()).hexdigest()
            valid = (query['sign'][0] == expected
                     and wrapper['sign'] == hashlib.md5((wrapper['msg']+'MkmC9SoIw6xCkSKHhJ7b5D2r51kBiREr').encode()).hexdigest()
                     and message['guid'] == 'fixture-visitor'
                     and message['vid'] == 'XFixtureVideo=='
                     and message['mat'] == wrapper['mat']
                     and '_m_h5_tk_enc=fixture-encrypted' in self.headers.get('Cookie', ''))
        except (ValueError, KeyError, TypeError):
            valid = False
        if not valid:
            self.send_error(403)
            return
        inner = {'code': 0, 'data': {'result': [{'playat': wrapper['mat'] * 60000 + 1250,
                   'content': 'fixture minute '+str(wrapper['mat']), 'propertis': '{"color":65280}'}]}}
        data = json.dumps({'ret': ['SUCCESS::fixture'], 'data': {'result': json.dumps(inner)}}).encode()
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
